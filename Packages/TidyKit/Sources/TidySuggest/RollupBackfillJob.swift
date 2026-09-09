import Foundation
import TidyCore
import TidyStore

/// Recomputes every day's `daily_rollups` row once after a data migration changed what the rollups
/// are derived from.
///
/// `writeRollups` re-rolls today and yesterday on every pipeline pass; older days are frozen. When
/// `v3-loginwindow-away-gaps` deleted 409 hours of lock-screen sessions, every frozen day's
/// `observed_seconds`, `capture_health` and context-switch figures became stale with no code path
/// to refresh them. This walks every day from the earliest session to today while
/// `MetadataKey.rollupsRecomputedFor` is **absent** — the migration that rewrote history deletes
/// it in its own transaction (`AwayGapBackfill.invalidateRollups`), so the coupling lives where the
/// cause is and no version string has to be bumped in this module. It has a production call site in
/// `runPipelineOnce`, pinned by the guardrail test, because a backfill nobody calls is this repo's
/// signature failure.
///
/// A day that throws is logged and skipped, and the marker is still written: the alternative —
/// leave the marker unset — repeats the full walk on every pass forever (review finding).
public struct RollupBackfillJob: Sendable {
    /// The value written when the walk completes. Informational; presence is what matters.
    public static let marker = "v3-loginwindow-away-gaps"

    private let db: AppDatabase
    private let config: Config
    private let selfPersonId: String?
    private let timeZone: TimeZone
    private let clock: TidyClock
    private let logger: TidyLogger?

    public init(db: AppDatabase, config: Config, selfPersonId: String?, timeZone: TimeZone,
                clock: TidyClock = SystemClock(), logger: TidyLogger? = nil) {
        self.db = db; self.config = config; self.selfPersonId = selfPersonId
        self.timeZone = timeZone; self.clock = clock; self.logger = logger
    }

    public struct Outcome: Equatable, Sendable {
        public var daysRolled = 0
        public var daysFailed = 0
        public init() {}
    }

    /// No-op (one metadata read) while the marker is present.
    @discardableResult
    public func runIfNeeded() throws -> Outcome {
        var outcome = Outcome()
        if try db.metadata(MetadataKey.rollupsRecomputedFor) != nil { return outcome }
        if let earliest = try db.earliestSessionStart() {
            // Built only when there is work: the pipeline pass must not pay for an assembler on
            // the way to a no-op.
            let assembler = RecapAssembler(db: db, config: config, clock: clock, selfPersonId: selfPersonId)
            for day in LocalDay.days(from: Date(timeIntervalSince1970: TimeInterval(earliest)),
                                     through: clock.now, timeZone: timeZone) {
                do {
                    _ = try assembler.writeRollup(day: day.day, from: day.from, to: day.to)
                    outcome.daysRolled += 1
                } catch {
                    outcome.daysFailed += 1
                    logger?.error("rollup backfill skipped a day", ["day": day.day, "error": "\(error)"])
                }
            }
        }
        try db.setMetadata(MetadataKey.rollupsRecomputedFor, Self.marker, clock: clock)
        return outcome
    }
}
