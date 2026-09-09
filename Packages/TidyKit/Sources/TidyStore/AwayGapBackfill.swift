import Foundation
import GRDB

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
    /// Mirrors `TidyCapture.AwayApps` — TidyStore cannot import TidyCapture, and the list is two
    /// bundle ids. A test pins that the two stay equal.
    public static let awayBundleIds: [String] = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"]

    /// A single sample longer than this with no lock screen in it is almost certainly unattended.
    /// Same ceiling `ContextSwitchAnalyzer.maxPlausibleFocusSeconds` uses (2 h).
    public static let unattendedCeilingSeconds: Int64 = 7200

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
            try db.execute(sql: "DELETE FROM activity_samples WHERE id = ?", arguments: [id])
            report.samplesDeleted += 1
        }

        let keys = awayBundleIds.map { "app:" + $0 }
        try db.execute(sql: """
            DELETE FROM sessions WHERE kind = 'screen' AND context_key IN (\(placeholders))
            """, arguments: StatementArguments(keys))
        report.sessionsDeleted = db.changesCount

        report.unattendedSamplesLeft = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM activity_samples
            WHERE COALESCE(ended_at, started_at) - started_at > ?
            """, arguments: [unattendedCeilingSeconds]) ?? 0
        return report
    }
}
