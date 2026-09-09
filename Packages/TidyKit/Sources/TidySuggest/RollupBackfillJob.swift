import Foundation
import TidyCore
import TidyStore

/// Recomputes every day's `daily_rollups` row once after a data migration changed what the rollups
/// are derived from.
///
/// `writeRollups` re-rolls today and yesterday on every pipeline pass; older days are frozen. When
/// `v3-loginwindow-away-gaps` deleted 409 hours of lock-screen sessions, every frozen day's
/// `observed_seconds`, `capture_health` and context-switch figures became stale with no code path
/// to refresh them. This walks every day from the earliest session to today, keyed on
/// `MetadataKey.rollupsRecomputedFor`, so it runs exactly once per migration name and is a no-op
/// forever after — and it has a production call site in `runPipelineOnce`, pinned by the guardrail
/// test, because a backfill nobody calls is this repo's signature failure.
public struct RollupBackfillJob: Sendable {
    /// The migration whose consequences the rollups must reflect. Bump when a later data
    /// migration changes session or sample history again.
    public static let currentVersion = "v3-loginwindow-away-gaps"

    private let db: AppDatabase
    private let assembler: RecapAssembler
    private let timeZone: TimeZone
    private let clock: TidyClock

    public init(db: AppDatabase, assembler: RecapAssembler, timeZone: TimeZone, clock: TidyClock = SystemClock()) {
        self.db = db; self.assembler = assembler; self.timeZone = timeZone; self.clock = clock
    }

    /// Returns the number of days re-rolled (0 when already done for `currentVersion`).
    @discardableResult
    public func runIfNeeded(version: String = RollupBackfillJob.currentVersion) throws -> Int {
        if try db.metadata(MetadataKey.rollupsRecomputedFor) == version { return 0 }
        guard let earliest = try db.earliestSessionStart() else {
            try db.setMetadata(MetadataKey.rollupsRecomputedFor, version, clock: clock)
            return 0
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = timeZone

        var day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(earliest)))
        let today = calendar.startOfDay(for: clock.now)
        var count = 0
        while day <= today {
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            _ = try assembler.writeRollup(day: formatter.string(from: day),
                                          from: Int64(day.timeIntervalSince1970),
                                          to: Int64(next.timeIntervalSince1970))
            count += 1
            day = next
        }
        try db.setMetadata(MetadataKey.rollupsRecomputedFor, version, clock: clock)
        return count
    }
}
