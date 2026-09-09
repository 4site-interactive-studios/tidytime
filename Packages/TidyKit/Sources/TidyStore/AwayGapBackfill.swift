import Foundation
import GRDB
import TidyCore

/// One-shot conversion of lock-screen "activity" into away gaps.
///
/// Before 2026-09-09 nothing detected sleep, lock or idle, so the frontmost reader recorded the
/// lock screen (`com.apple.loginwindow`) as an application: 594 samples, 222 sessions, 409 hours —
/// 54% of every recorded screen hour, and the denominator of every observed-time and attribution
/// rate the product reported. That time was not observed work; it was the user being away, and
/// the table for that is `away_gaps`.
///
/// Runs as the `v3-loginwindow-away-gaps` migration. For each sample whose app is in the away set,
/// one `away_gaps` row (`cause = 'lock'`) covering the sample's span replaces it, and the screen
/// sessions built from those samples are deleted. Sessions on either side are untouched — the lock
/// screen was its own sample, so its neighbours already ended where it began.
///
/// What this cannot recover: samples of a real application that ran unattended *without* the lock
/// screen appearing (display sleep, a lid closed on an unlocked machine). They look like a person
/// sitting in one app for nine hours and there is no signal in the data to say otherwise. They are
/// left as they are, counted in `Report.unattendedSamplesLeft`, and age out with retention; the live
/// idle detector prevents new ones.
public enum AwayGapBackfill {
    /// The same two bundle ids capture refuses to record — `AwayApps` lives in TidyCore for that.
    public static var awayBundleIds: [String] { AwayApps.bundleIds.sorted() }

    /// A single sample longer than this with no lock screen in it is almost certainly unattended.
    /// The ceiling the context-switch metric already uses, not a second copy of the number.
    public static let unattendedCeilingSeconds = Int64(ContextSwitchAnalyzer.defaultMaxPlausibleFocusSeconds)

    public struct Report: Equatable, Sendable {
        public var gapsInserted = 0
        public var samplesDeleted = 0
        public var sessionsDeleted = 0
        public var unattendedSamplesLeft = 0
        public init() {}
    }

    @discardableResult
    public static func apply(_ db: Database, now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> Report {
        var report = Report()
        let placeholders = awayBundleIds.map { _ in "?" }.joined(separator: ",")

        // The span of each away sample: its own ended_at, else the next sample's start (the way the
        // sessionizer reads an open sample), else zero length.
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, started_at, end_at FROM (
                SELECT id, started_at, app_bundle_id,
                       COALESCE(ended_at, LEAD(started_at) OVER (ORDER BY started_at, id), started_at) AS end_at
                FROM activity_samples
            ) WHERE app_bundle_id IN (\(placeholders))
            """, arguments: StatementArguments(awayBundleIds))
        for row in rows {
            let id: Int64 = row["id"]
            let start: Int64 = row["started_at"]
            let end: Int64 = row["end_at"]
            if end > start {
                try db.execute(sql: """
                    INSERT INTO away_gaps (started_at, ended_at, duration_seconds, cause, created_at)
                    VALUES (?, ?, ?, 'lock', ?)
                    """, arguments: [start, end, end - start, now])
                report.gapsInserted += 1
            }
            // Children first, explicitly: a migration runs with foreign keys OFF and is checked
            // before commit, so relying on the cascade would abort the migration on any orphan.
            try db.execute(sql: "DELETE FROM page_snapshots WHERE sample_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM activity_samples WHERE id = ?", arguments: [id])
            report.samplesDeleted += 1
        }

        let keys = awayBundleIds.map { "app:" + $0 }
        try db.execute(sql: """
            DELETE FROM sessions WHERE kind = 'screen' AND context_key IN (\(placeholders))
            """, arguments: StatementArguments(keys))
        report.sessionsDeleted = db.changesCount

        // History changed under the rollups: clear the marker so `RollupBackfillJob` re-rolls every
        // day once. The coupling lives here, in the migration that causes it, not in a version
        // string somebody has to remember to bump in another module.
        try invalidateRollups(db)

        report.unattendedSamplesLeft = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM activity_samples
            WHERE COALESCE(ended_at, started_at) - started_at > ?
            """, arguments: [unattendedCeilingSeconds]) ?? 0
        return report
    }

    /// Any data migration that rewrites sample or session history calls this in its transaction.
    public static func invalidateRollups(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM app_metadata WHERE key = ?", arguments: [MetadataKey.rollupsRecomputedFor])
    }
}
