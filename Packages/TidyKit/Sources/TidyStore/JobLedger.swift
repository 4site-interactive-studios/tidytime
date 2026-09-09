import Foundation
import GRDB
import TidyCore

/// The answer to "is this job actually running?" — recorded by the job itself, every time.
///
/// This repo's signature failure is a component that exists, compiles, is unit-tested, and is
/// never called. Seven were found that way: six pipeline jobs in one week, then the whole away
/// subsystem, which left the lock screen counted as work for 44 days. Tables sat at zero rows and
/// no test noticed, because a job that is never invoked cannot fail.
///
/// So every job now writes one `job_runs` row on each run — started, finished, outcome, detail —
/// and `JobRegistry` lists every job the product *expects* to run with its cadence. The Doctor
/// pane and `make diagnose` render the registry against the ledger, which turns "defined, never
/// invoked" from something an audit finds after weeks into a red row that says **never ran**.
/// `JobLedgerTests` runs one pipeline pass and fails on any registered pipeline job with no row.
///
/// `skipped` is an outcome, not an absence: an ingest source with no credential records that it
/// was *considered* and why, so "never ran" is reserved for the case that matters.
public struct JobRun: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "job_runs"
    public var name: String
    public var lastStartedAt: Int64
    public var lastFinishedAt: Int64?
    public var lastOutcome: String       // 'ok' | 'failed' | 'skipped'
    public var lastDetail: String?
    public var runCount: Int
    public var failCount: Int

    public init(name: String, lastStartedAt: Int64, lastFinishedAt: Int64?, lastOutcome: String,
                lastDetail: String?, runCount: Int, failCount: Int) {
        self.name = name; self.lastStartedAt = lastStartedAt; self.lastFinishedAt = lastFinishedAt
        self.lastOutcome = lastOutcome; self.lastDetail = lastDetail
        self.runCount = runCount; self.failCount = failCount
    }

    enum CodingKeys: String, CodingKey {
        case name, lastStartedAt = "last_started_at", lastFinishedAt = "last_finished_at"
        case lastOutcome = "last_outcome", lastDetail = "last_detail"
        case runCount = "run_count", failCount = "fail_count"
    }
}

public enum JobOutcome: String, Sendable {
    case ok, failed, skipped
}

/// Every job the product expects to run. Adding a job here without a call site makes
/// `JobLedgerTests` fail; adding a call site without registering it makes the guardrail test fail.
public enum JobRegistry {
    public struct Job: Sendable, Equatable {
        public let name: String
        public let group: String
        /// How often it should run when the app is capturing. `nil` = once (a backfill) or on demand.
        public let expectedEverySeconds: Int?
        public init(_ name: String, group: String, every: Int?) {
            self.name = name; self.group = group; self.expectedEverySeconds = every
        }
    }

    public static let pipelineInterval = 300
    public static let ingestInterval = 900

    public static let all: [Job] = [
        Job("CaptureHeartbeat", group: "capture", every: 20),
        Job("SessionBuildJob", group: "pipeline", every: pipelineInterval),
        Job("EntityBootstrap", group: "pipeline", every: pipelineInterval),
        Job("DayClassifier", group: "pipeline", every: pipelineInterval),
        Job("SuggestionEngine", group: "pipeline", every: pipelineInterval),
        Job("ResolutionQuestionGenerator", group: "pipeline", every: pipelineInterval),
        Job("RecapRefresh", group: "pipeline", every: pipelineInterval),
        Job("DailyRollup", group: "pipeline", every: pipelineInterval),
        Job("RollupBackfillJob", group: "pipeline", every: pipelineInterval),
        Job("RetentionJob", group: "pipeline", every: pipelineInterval),
        Job("DiagnosticsSnapshot", group: "pipeline", every: pipelineInterval),
        Job("ProductiveSync", group: "ingest", every: ingestInterval),
        Job("FathomSync", group: "ingest", every: ingestInterval),
        Job("SlackSync", group: "ingest", every: ingestInterval),
        Job("CalendarSync", group: "ingest", every: ingestInterval),
    ]

    public static func names(group: String) -> [String] { all.filter { $0.group == group }.map(\.name) }
}

/// One registry job read against the ledger.
public struct JobStatus: Sendable, Equatable {
    public enum Verdict: String, Sendable { case neverRan = "NEVER RAN", ok, failed, skipped, stale }
    public let job: JobRegistry.Job
    public let run: JobRun?
    public let verdict: Verdict
    public let ageSeconds: Int?

    /// One line for Doctor / diagnostics: `ok · 42s ago` / `NEVER RAN` / `failed · 3m ago — <detail>`.
    public var summary: String {
        var s = verdict.rawValue
        if let ageSeconds { s += " · \(Self.age(ageSeconds)) ago" }
        if let every = job.expectedEverySeconds, verdict != .neverRan { s += " (every \(Self.age(every)))" }
        if let d = run?.lastDetail, !d.isEmpty, verdict == .failed || verdict == .skipped { s += " — \(d)" }
        return s
    }

    static func age(_ seconds: Int) -> String {
        if seconds < 90 { return "\(seconds)s" }
        if seconds < 5400 { return "\(seconds / 60)m" }
        if seconds < 172_800 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}

public enum JobHealth {
    /// A run older than this many multiples of its cadence is stale — the timer that drives it
    /// has stopped, which is the live form of "never called".
    public static let staleMultiple = 3

    public static func report(runs: [JobRun], registry: [JobRegistry.Job] = JobRegistry.all,
                              now: Int64) -> [JobStatus] {
        let byName = Dictionary(runs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return registry.map { job in
            guard let run = byName[job.name] else {
                return JobStatus(job: job, run: nil, verdict: .neverRan, ageSeconds: nil)
            }
            let age = Int(max(0, now - run.lastStartedAt))
            let verdict: JobStatus.Verdict
            switch JobOutcome(rawValue: run.lastOutcome) ?? .failed {
            case .failed: verdict = .failed
            case .skipped: verdict = .skipped
            case .ok:
                if let every = job.expectedEverySeconds, age > every * staleMultiple { verdict = .stale }
                else { verdict = .ok }
            }
            return JobStatus(job: job, run: run, verdict: verdict, ageSeconds: age)
        }
    }

    /// The names that need attention — what the menu bar / Doctor badge should count.
    public static func problems(_ statuses: [JobStatus]) -> [JobStatus] {
        statuses.filter { $0.verdict == .neverRan || $0.verdict == .failed || $0.verdict == .stale }
    }
}

extension AppDatabase {
    /// Upsert the ledger row for `name`. `finishedAt` nil means "started, not finished".
    public func recordJobRun(_ name: String, startedAt: Int64, finishedAt: Int64?,
                             outcome: JobOutcome, detail: String? = nil) throws {
        try writer.write { db in
            let prior = try JobRun.fetchOne(db, key: name)
            let row = JobRun(
                name: name, lastStartedAt: startedAt, lastFinishedAt: finishedAt,
                lastOutcome: outcome.rawValue,
                // Detail can echo an error body; redacted here so the ledger is as safe as the log.
                lastDetail: detail.map { String(Redactor.redact($0).prefix(500)) },
                runCount: (prior?.runCount ?? 0) + 1,
                failCount: (prior?.failCount ?? 0) + (outcome == .failed ? 1 : 0))
            try row.save(db)
        }
    }

    public func jobRuns() throws -> [JobRun] {
        try writer.read { db in try JobRun.order(sql: "name").fetchAll(db) }
    }

    /// Run `body` and record the outcome under `name`. Rethrows, so the caller's own error policy
    /// (`try` vs `try?`) is unchanged; the ledger row is written either way.
    @discardableResult
    public func track<T>(_ name: String, clock: TidyClock = SystemClock(), _ body: () throws -> T) throws -> T {
        let started = Int64(clock.now.timeIntervalSince1970)
        do {
            let result = try body()
            try? recordJobRun(name, startedAt: started, finishedAt: Int64(clock.now.timeIntervalSince1970), outcome: .ok)
            return result
        } catch {
            try? recordJobRun(name, startedAt: started, finishedAt: Int64(clock.now.timeIntervalSince1970),
                              outcome: .failed, detail: "\(error)")
            throw error
        }
    }

    /// Async variant for the ingest engines.
    @discardableResult
    public func track<T>(_ name: String, clock: TidyClock = SystemClock(),
                         _ body: () async throws -> T) async throws -> T {
        let started = Int64(clock.now.timeIntervalSince1970)
        do {
            let result = try await body()
            try? recordJobRun(name, startedAt: started, finishedAt: Int64(clock.now.timeIntervalSince1970), outcome: .ok)
            return result
        } catch {
            try? recordJobRun(name, startedAt: started, finishedAt: Int64(clock.now.timeIntervalSince1970),
                              outcome: .failed, detail: "\(error)")
            throw error
        }
    }

    /// A job that was considered and deliberately not run, with the reason — so Doctor can tell
    /// "no credential" from "nobody calls this".
    public func recordJobSkipped(_ name: String, reason: String, clock: TidyClock = SystemClock()) {
        let now = Int64(clock.now.timeIntervalSince1970)
        try? recordJobRun(name, startedAt: now, finishedAt: now, outcome: .skipped, detail: reason)
    }

    /// Registry read against the ledger, for Doctor and diagnostics.
    public func jobStatuses(now: Int64 = Int64(Date().timeIntervalSince1970)) -> [JobStatus] {
        JobHealth.report(runs: (try? jobRuns()) ?? [], now: now)
    }
}
