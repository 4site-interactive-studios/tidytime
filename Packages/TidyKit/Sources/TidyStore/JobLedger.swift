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

}

extension AppDatabase {
    /// Upsert the ledger row for `name`. `finishedAt` nil means "started, not finished".
    /// `secrets` are the caller's known secret values: error bodies from providers echo the very
    /// token that failed, and pattern redaction alone misses a token that has no recognisable shape
    /// (G6 — the same reason `sync_state.last_error` takes them).
    public func recordJobRun(_ name: String, startedAt: Int64, finishedAt: Int64?,
                             outcome: JobOutcome, detail: String? = nil, secrets: [String] = []) throws {
        let safeDetail = detail.map { String(Redactor.redact($0, secrets: secrets).prefix(500)) }
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO job_runs (name, last_started_at, last_finished_at, last_outcome, last_detail, run_count, fail_count)
                VALUES (?, ?, ?, ?, ?, 1, ?)
                ON CONFLICT(name) DO UPDATE SET
                    last_started_at = excluded.last_started_at,
                    last_finished_at = excluded.last_finished_at,
                    last_outcome = excluded.last_outcome,
                    last_detail = excluded.last_detail,
                    run_count = run_count + 1,
                    fail_count = fail_count + excluded.fail_count
                """, arguments: [name, startedAt, finishedAt, outcome.rawValue, safeDetail, outcome == .failed ? 1 : 0])
        }
    }

    public func jobRuns() throws -> [JobRun] {
        try writer.read { db in try JobRun.order(sql: "name").fetchAll(db) }
    }

    /// When `name` last started, if ever. The `CaptureHeartbeat` row doubles as "last known alive".
    public func lastJobStart(_ name: String) throws -> Int64? {
        try writer.read { db in try JobRun.fetchOne(db, key: name)?.lastStartedAt }
    }

    /// Run `body` and record the outcome under `name`. Rethrows, so the caller's own error policy
    /// (`try` vs `try?`) is unchanged; the ledger row is written either way. A ledger write that
    /// itself fails is logged through `logger` — silently losing it would make Doctor report a job
    /// that ran as NEVER RAN with nothing to explain the discrepancy.
    @discardableResult
    public func track<T>(_ name: String, clock: TidyClock = SystemClock(), secrets: [String] = [],
                         logger: TidyLogger? = nil, _ body: () throws -> T) throws -> T {
        let started = Int64(clock.now.timeIntervalSince1970)
        do {
            let result = try body()
            finish(name, started: started, clock: clock, error: nil, secrets: secrets, logger: logger)
            return result
        } catch {
            finish(name, started: started, clock: clock, error: error, secrets: secrets, logger: logger)
            throw error
        }
    }

    /// Async variant for the ingest engines.
    @discardableResult
    public func track<T>(_ name: String, clock: TidyClock = SystemClock(), secrets: [String] = [],
                         logger: TidyLogger? = nil, _ body: () async throws -> T) async throws -> T {
        let started = Int64(clock.now.timeIntervalSince1970)
        do {
            let result = try await body()
            finish(name, started: started, clock: clock, error: nil, secrets: secrets, logger: logger)
            return result
        } catch {
            finish(name, started: started, clock: clock, error: error, secrets: secrets, logger: logger)
            throw error
        }
    }

    /// The one outcome policy both `track` overloads share.
    private func finish(_ name: String, started: Int64, clock: TidyClock, error: Error?,
                        secrets: [String], logger: TidyLogger?) {
        do {
            try recordJobRun(name, startedAt: started, finishedAt: Int64(clock.now.timeIntervalSince1970),
                             outcome: error == nil ? .ok : .failed, detail: error.map { "\($0)" }, secrets: secrets)
        } catch {
            logger?.error("job ledger write failed", ["job": name, "error": "\(error)"])
        }
    }

    /// A job that was considered and deliberately not run, with the reason — so Doctor can tell
    /// "no credential" from "nobody calls this".
    public func recordJobSkipped(_ name: String, reason: String, clock: TidyClock = SystemClock(),
                                 logger: TidyLogger? = nil) {
        let now = Int64(clock.now.timeIntervalSince1970)
        do { try recordJobRun(name, startedAt: now, finishedAt: now, outcome: .skipped, detail: reason) }
        catch { logger?.error("job ledger write failed", ["job": name, "error": "\(error)"]) }
    }

    /// Registry read against the ledger, for Doctor and diagnostics.
    public func jobStatuses(now: Int64 = Int64(Date().timeIntervalSince1970)) -> [JobStatus] {
        JobHealth.report(runs: (try? jobRuns()) ?? [], now: now)
    }
}
