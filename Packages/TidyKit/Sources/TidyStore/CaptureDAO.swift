import Foundation
import GRDB
import TidyCore

/// Insert/fetch helpers for the capture tables + `sync_state`, plus the retention job. Kept as
/// `AppDatabase` extensions so callers use one handle.
extension AppDatabase {
    // MARK: activity_samples

    @discardableResult
    public func insertSample(_ sample: ActivitySample) throws -> Int64 {
        try writer.write { db in var s = sample; try s.insert(db); return s.id! }
    }

    /// Close the previously open sample (set `ended_at`) when a new context supersedes it.
    public func closeOpenSample(before newStart: Int64) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE activity_samples SET ended_at = ?
                WHERE ended_at IS NULL AND started_at <= ?
                """, arguments: [newStart, newStart])
        }
    }

    public func samples(from start: Int64, to end: Int64) throws -> [ActivitySample] {
        try writer.read { db in
            try ActivitySample
                .filter(sql: "started_at >= ? AND started_at < ?", arguments: [start, end])
                .order(sql: "started_at ASC")
                .fetchAll(db)
        }
    }

    // MARK: page_snapshots

    @discardableResult
    public func insertPageSnapshot(_ snapshot: PageSnapshot) throws -> Int64 {
        try writer.write { db in var s = snapshot; try s.insert(db); return s.id! }
    }

    /// Page-snapshot texts captured within a time window (newest first, capped) — lexical evidence
    /// for classifying a session (rungs 1–2 are local, so no gate needed here).
    ///
    /// `host` scopes the result to the session's own context. Without it, a brief detour that the
    /// Sessionizer *absorbs* into a session (detour tolerance, default 120s) contributes its page
    /// text — and because the ordering is newest-first with a small limit, a 90-second glance at an
    /// unrelated site could supply 100% of a two-hour session's attribution evidence (R1-3).
    public func pageTexts(from start: Int64, to end: Int64, limit: Int = 3, host: String? = nil) throws -> [String] {
        try writer.read { db in
            if let host, !host.isEmpty {
                return try String.fetchAll(db, sql: """
                    SELECT text FROM page_snapshots
                    WHERE captured_at >= ? AND captured_at < ?
                      AND (url LIKE ? OR url LIKE ? OR url LIKE ?)
                    ORDER BY captured_at DESC LIMIT ?
                    """, arguments: [start, end,
                                     "%://\(host)/%", "%://\(host)", "%://www.\(host)%", limit])
            }
            return try String.fetchAll(db, sql: """
                SELECT text FROM page_snapshots WHERE captured_at >= ? AND captured_at < ?
                ORDER BY captured_at DESC LIMIT ?
                """, arguments: [start, end, limit])
        }
    }

    /// Most recent snapshot hash for a URL, used to skip storing duplicate page text.
    public func latestSnapshotHash(url: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT content_hash FROM page_snapshots WHERE url = ? ORDER BY captured_at DESC LIMIT 1
                """, arguments: [url])
        }
    }

    // MARK: sessions

    @discardableResult
    public func insertSession(_ session: Session) throws -> Int64 {
        try writer.write { db in var s = session; try s.insert(db); return s.id! }
    }

    public func sessions(from start: Int64, to end: Int64) throws -> [Session] {
        try writer.read { db in
            try Session
                .filter(sql: "started_at >= ? AND started_at < ?", arguments: [start, end])
                .order(sql: "started_at ASC")
                .fetchAll(db)
        }
    }

    // MARK: away_gaps

    /// All away gaps overlapping a window — used to clip unattended time out of the
    /// context-switch metric (round-2 finding R1-2).
    public func awayGaps(from start: Int64, to end: Int64) throws -> [AwayGap] {
        try writer.read { db in
            try AwayGap
                .filter(sql: "ended_at > ? AND started_at < ?", arguments: [start, end])
                .order(sql: "started_at ASC").fetchAll(db)
        }
    }

    @discardableResult
    public func insertAwayGap(_ gap: AwayGap) throws -> Int64 {
        try writer.write { db in var g = gap; try g.insert(db); return g.id! }
    }

    // MARK: sync_state

    public func syncState(_ source: String) throws -> SyncState? {
        try writer.read { db in try SyncState.fetchOne(db, key: source) }
    }

    public func saveSyncState(_ state: SyncState) throws {
        try writer.write { db in try state.save(db) }
    }
}

/// Purges high-volume/sensitive rows older than the configured retention window (guardrail G9).
/// Tables not yet created (later phases) are skipped. `page_snapshots` also cascade-delete with
/// their `activity_samples`, but we purge them by `captured_at` too for defensiveness.
public struct RetentionJob: Sendable {
    /// table → its timestamp column used for the age comparison.
    public static let timestampColumns: [String: String] = [
        "activity_samples": "started_at",
        "page_snapshots": "captured_at",
        "slack_messages": "posted_at",
    ]

    public init() {}

    /// Delete rows older than each table's retention window. Returns table → rows deleted.
    @discardableResult
    public func purge(_ db: AppDatabase, retentionDays: [String: Int], now: Date) throws -> [String: Int] {
        var deleted: [String: Int] = [:]
        try db.writer.write { database in
            let existing = Set(try String.fetchAll(database, sql:
                "SELECT name FROM sqlite_master WHERE type='table'"))
            for (table, days) in retentionDays {
                let cutoff = Int64(now.timeIntervalSince1970) - Int64(days) * 86_400
                if let column = Self.timestampColumns[table], existing.contains(table) {
                    try database.execute(
                        sql: "DELETE FROM \"\(table)\" WHERE \"\(column)\" < ?", arguments: [cutoff])
                    deleted[table] = database.changesCount
                } else if table == "transcript_utterances",
                          existing.contains("transcript_utterances"), existing.contains("meetings") {
                    // transcript_utterances has no absolute timestamp of its own (only start_seconds
                    // offsets), so purge via the parent meeting's recording/fetch time. The meetings
                    // summary row is KEPT (data-model.md); only the raw utterances age out (G9).
                    try database.execute(sql: """
                        DELETE FROM transcript_utterances WHERE meeting_id IN
                            (SELECT id FROM meetings WHERE COALESCE(recording_start, fetched_at) < ?)
                        """, arguments: [cutoff])
                    deleted[table] = database.changesCount
                }
            }
        }
        return deleted
    }
}
