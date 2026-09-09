import XCTest
import Foundation
import TidyCore
import TidyStore
import TidySurface

/// The orphan detector.
///
/// Seven components in this repo were found written, tested, and never called — the last one left
/// the lock screen counted as work for 44 days. A job that is never invoked cannot fail, so no
/// test noticed. These tests make the *absence of a run* the failure: one pipeline pass must leave
/// a `job_runs` row for every registered pipeline job, and an ingest pass with no credentials must
/// leave a `skipped` row for every source, so "never ran" is reserved for the real thing.
@MainActor
final class JobLedgerTests: XCTestCase {
    private var dir: URL!
    override func setUp() async throws { dir = try TestSupport.makeTempDir() }
    override func tearDown() async throws { TestSupport.cleanup(dir) }

    private func makeEnv() throws -> (AppDatabase, AppEnvironment) {
        let db = try AppDatabase.inMemory()
        return (db, AppEnvironment(db: db, config: Config(), paths: AppPaths(supportDirectory: dir)))
    }

    // MARK: The detector

    func testOnePipelinePassLeavesARowForEveryRegisteredPipelineJob() throws {
        let (db, env) = try makeEnv()
        env.runPipelineOnce()
        let ran = Set(try db.jobRuns().map(\.name))
        for name in JobRegistry.names(group: "pipeline") {
            XCTAssertTrue(ran.contains(name),
                          "\(name) is registered and one pipeline pass did not record it. Either it "
                        + "has no call site (this repo's signature failure) or the call site is not "
                        + "wrapped in db.track(\"\(name)\").")
        }
        let statuses = db.jobStatuses()
        let pipeline = statuses.filter { $0.job.group == "pipeline" }
        XCTAssertTrue(pipeline.allSatisfy { $0.verdict == .ok },
                      pipeline.filter { $0.verdict != .ok }.map { "\($0.job.name): \($0.summary)" }.joined(separator: "; "))
    }

    func testIngestWithNoCredentialsRecordsSkippedNotNeverRan() async throws {
        let (db, env) = try makeEnv()
        let coordinator = IngestCoordinator(db: db, config: env.config, secrets: InMemorySecretStore())
        await coordinator.runAll()
        let statuses = db.jobStatuses().filter { $0.job.group == "ingest" }
        XCTAssertEqual(statuses.count, 4)
        for s in statuses {
            XCTAssertEqual(s.verdict, .skipped, s.job.name)
            XCTAssertFalse(s.run?.lastDetail?.isEmpty ?? true, "\(s.job.name) must say why it was skipped")
        }
    }

    /// The structural half: a job the pipeline tracks must be registered, or Doctor never lists it.
    func testEveryTrackedJobIsRegistered() throws {
        let registered = Set(JobRegistry.all.map(\.name))
        for file in ["Packages/TidyKit/Sources/TidySurface/AppEnvironment.swift",
                     "Packages/TidyKit/Sources/TidySurface/IngestCoordinator.swift",
                     "Packages/TidyKit/Sources/TidyCapture/LiveCapture.swift"] {
            let src = try String(contentsOf: TestSupport.repoRoot().appendingPathComponent(file), encoding: .utf8)
            let regex = try NSRegularExpression(pattern: #"(?:track|recordJobRun|recordJobSkipped)\("([A-Za-z]+)""#)
            let range = NSRange(src.startIndex..<src.endIndex, in: src)
            for m in regex.matches(in: src, range: range) {
                let name = String(src[Range(m.range(at: 1), in: src)!])
                XCTAssertTrue(registered.contains(name), "\(name) is tracked in \(file) but not in JobRegistry")
            }
        }
        for source in IngestCoordinator.Source.allCases {
            XCTAssertTrue(registered.contains(IngestCoordinator.jobName(source)))
        }
    }

    // MARK: Verdicts

    func testVerdicts() throws {
        let now: Int64 = 100_000
        let jobs = [JobRegistry.Job("A", group: "pipeline", every: 300),
                    JobRegistry.Job("B", group: "pipeline", every: 300),
                    JobRegistry.Job("C", group: "pipeline", every: 300),
                    JobRegistry.Job("D", group: "ingest", every: 900),
                    JobRegistry.Job("E", group: "pipeline", every: nil)]
        func run(_ name: String, ago: Int64, _ outcome: String, _ detail: String? = nil) -> JobRun {
            JobRun(name: name, lastStartedAt: now - ago, lastFinishedAt: now - ago + 1, lastOutcome: outcome,
                   lastDetail: detail, runCount: 1, failCount: outcome == "failed" ? 1 : 0)
        }
        let runs: [JobRun] = [run("A", ago: 60, "ok"), run("B", ago: 2000, "ok"),
                              run("C", ago: 10, "failed", "boom"), run("D", ago: 10, "skipped", "no credential")]
        let report = JobHealth.report(runs: runs, registry: jobs, now: now)
        let expected: [JobStatus.Verdict] = [.ok, .stale, .failed, .skipped, .neverRan]
        XCTAssertEqual(report.map { $0.verdict }, expected)
        XCTAssertEqual(report[0].summary, "ok · 60s ago (every 5m)")
        XCTAssertEqual(report[2].summary, "failed · 10s ago (every 5m) — boom")
        XCTAssertEqual(report[4].summary, "NEVER RAN")
    }

    func testTrackRecordsOutcomeAndRethrows() throws {
        let db = try AppDatabase.inMemory()
        let clock = FixedClock(Date(timeIntervalSince1970: 500))
        XCTAssertEqual(try db.track("X", clock: clock) { 42 }, 42)
        XCTAssertThrowsError(try db.track("X", clock: clock) { throw TidyError.config("bad") })
        let run = try XCTUnwrap(try db.jobRuns().first)
        XCTAssertEqual(run.lastOutcome, "failed")
        XCTAssertEqual(run.runCount, 2)
        XCTAssertEqual(run.failCount, 1)
        XCTAssertTrue(run.lastDetail?.contains("bad") ?? false)
    }

    func testKnownSecretValuesAreRedactedFromDetail() throws {
        // A provider error body echoes the exact token that failed; it has no recognisable shape,
        // so only the caller's known-secret list can catch it (G6, same as sync_state.last_error).
        let db = try AppDatabase.inMemory()
        let secret = "super-secret-refresh-token-value"
        XCTAssertThrowsError(try db.track("CalendarSync", secrets: [secret]) {
            throw TidyError.ingest("invalid_grant: bad token \(secret)")
        })
        let run = try XCTUnwrap(try db.jobRuns().first)
        XCTAssertFalse(run.lastDetail?.contains(secret) ?? true)
        XCTAssertTrue(run.lastDetail?.contains(Redactor.mask) ?? false)
    }

    func testDetailIsRedacted() throws {
        let db = try AppDatabase.inMemory()
        try db.recordJobRun("X", startedAt: 1, finishedAt: 2, outcome: .failed,
                            detail: "401 for token " + ["xoxp", "1234567890", "abcdefghijklmnop"].joined(separator: "-"))
        let run = try XCTUnwrap(try db.jobRuns().first)
        XCTAssertFalse(run.lastDetail?.contains("xoxp-") ?? true)
        XCTAssertTrue(run.lastDetail?.contains(Redactor.mask) ?? false)
    }

    // MARK: Surfaces

    func testDiagnosticsBundleListsNeverRanJobs() throws {
        let db = try AppDatabase.inMemory()
        let assembler = DiagnosticsAssembler(db: db, config: Config(), secrets: InMemorySecretStore(),
                                             logURL: dir.appendingPathComponent("log.jsonl"))
        let text = DiagnosticsBundle.render(assembler.assemble())
        XCTAssertTrue(text.contains("## Jobs"))
        XCTAssertTrue(text.contains("pipeline.SessionBuildJob: NEVER RAN"), text)
        try db.recordJobRun("SessionBuildJob", startedAt: Int64(Date().timeIntervalSince1970), finishedAt: nil, outcome: .ok)
        XCTAssertTrue(DiagnosticsBundle.render(assembler.assemble()).contains("pipeline.SessionBuildJob: ok"))
    }

    func testMigrationIsRegistered() throws {
        let db = try AppDatabase.inMemory()
        XCTAssertTrue(try db.appliedMigrations().contains("v3-job-runs"))
        XCTAssertEqual(try db.tableRowCounts()["job_runs"], 0)
    }
}
