import Foundation
import GRDB
import TidyCore

/// One-shot cleanup of credential material that reached the database before G10 existed.
///
/// The 2026-09-08 audit found 35 `activity_samples` URLs and 4 `page_snapshots` URLs with `code=`
/// in the query string, one `pd_tasks` description carrying a Google client secret, and two more
/// matching other token shapes. Every ingest path now scrubs on the way in; this rewrites what is
/// already there, using the same scrubber and redactor, so the two can never disagree about what
/// is acceptable on disk.
///
/// It runs as the `v3-credential-scrub` migration — once, inside the migrator's transaction, and
/// therefore before any other code can read the rows. A "startup job with a flag" would do the same
/// work with one more way to fail (the flag write) and one more orphan risk (the job is never
/// called). A migration cannot be skipped.
///
/// Columns are listed explicitly rather than discovered, because *which* columns are free text from
/// an external source is a judgement: `sessions.title` is derived from a scrubbed sample and
/// rebuilt daily, `entity_signals.token` is our own vocabulary, `sync_state.last_error` was already
/// redacted at the write. The guardrail test scans every TEXT column so a column missing from
/// this list surfaces as a failure rather than a silent gap.
public enum CredentialScrub {
    /// Table → text columns that are redacted in place.
    public static let redactedColumns: [(table: String, column: String)] = [
        ("activity_samples", "window_title"),
        ("page_snapshots", "title"),
        ("page_snapshots", "text"),
        ("pd_tasks", "description"),
        ("pd_time_entries", "note"),
        ("slack_messages", "text"),
    ]

    /// Table → URL column that is scrubbed in place; a `.drop` outcome deletes the row.
    /// Snapshots first, so a dropped snapshot is counted explicitly rather than disappearing
    /// through the `ON DELETE CASCADE` from its sample.
    public static let urlColumns: [(table: String, column: String)] = [
        ("page_snapshots", "url"),
        ("activity_samples", "url"),
    ]

    public struct Report: Equatable, Sendable {
        public var urlsRewritten = 0
        public var rowsDropped = 0
        public var textsRedacted = 0
        public init() {}
    }

    /// Apply to an open GRDB connection (a migration or a test). `identityQueryKeys` is the same
    /// allowlist capture uses; the migration passes none, because config is not available inside
    /// the migrator and the safe default is "keep nothing".
    @discardableResult
    public static func apply(_ db: Database, identityQueryKeys: [String] = []) throws -> Report {
        var report = Report()
        let scrubber = URLScrubber(identityQueryKeys: identityQueryKeys)
        let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"))

        for (table, column) in urlColumns where tables.contains(table) {
            // Only rows that can carry anything: a URL with no `?`, `#` or `@` is already clean.
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, "\(column)" AS v FROM "\(table)"
                WHERE "\(column)" LIKE '%?%' OR "\(column)" LIKE '%#%' OR "\(column)" LIKE '%@%'
                """)
            for row in rows {
                let id: Int64 = row["id"]
                let value: String = row["v"]
                switch scrubber.scrub(value) {
                case .drop:
                    try db.execute(sql: "DELETE FROM \"\(table)\" WHERE id = ?", arguments: [id])
                    report.rowsDropped += 1
                case .store(let safe) where safe != value:
                    try db.execute(sql: "UPDATE \"\(table)\" SET \"\(column)\" = ? WHERE id = ?",
                                   arguments: [safe, id])
                    report.urlsRewritten += 1
                case .store:
                    break
                }
            }
        }

        for (table, column) in redactedColumns where tables.contains(table) {
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid AS rid, "\(column)" AS v FROM "\(table)" WHERE "\(column)" IS NOT NULL
                """)
            for row in rows {
                let rid: Int64 = row["rid"]
                let value: String = row["v"]
                let safe = Redactor.redact(value)
                guard safe != value else { continue }
                try db.execute(sql: "UPDATE \"\(table)\" SET \"\(column)\" = ? WHERE rowid = ?",
                               arguments: [safe, rid])
                report.textsRedacted += 1
            }
        }
        return report
    }

    /// Every TEXT-affinity column in the schema, for the guardrail scan. Discovered, not listed,
    /// so a new table is covered the day it is created.
    public static func textColumns(_ db: Database) throws -> [(table: String, column: String)] {
        let tables = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
            """)
        var out: [(String, String)] = []
        for table in tables {
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")")
            for col in cols {
                let type = (col["type"] as String? ?? "").uppercased()
                if type.contains("TEXT") || type.contains("CHAR") || type.contains("CLOB") || type.isEmpty {
                    out.append((table, col["name"] as String))
                }
            }
        }
        return out
    }

    /// Credential shapes a stored value must never match. Shared with the guardrail test and the
    /// `diagnose` CLI so the definition of "clean" is written once.
    public static let forbiddenPatterns: [String] = [
        #"(?i)[?&#](code|access_token|id_token|refresh_token|client_secret|api_key|token|password)="#,
        #"GOCSPX-[A-Za-z0-9_\-]{10,}"#,
        #"AIzaSy[A-Za-z0-9_\-]{20,}"#,
        #"xox[baprse]-[A-Za-z0-9\-]{10,}"#,
        #"sk-[A-Za-z0-9\-]{16,}"#,
        #"ya29\.[A-Za-z0-9._\-]{10,}"#,
        #"4/0A[A-Za-z0-9_\-]{20,}"#,
        #"4%2F0A[A-Za-z0-9_\-]{20,}"#,
        #"(?:gh[pousr]|github_pat)_[A-Za-z0-9_]{20,}"#,
    ]

    /// Count of stored values matching any forbidden pattern, per `table.column`. Empty means clean.
    public static func violations(_ db: Database) throws -> [String: Int] {
        let regexes = forbiddenPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
        var out: [String: Int] = [:]
        for (table, column) in try textColumns(db) {
            let values = try String.fetchAll(db, sql: """
                SELECT "\(column)" FROM "\(table)" WHERE "\(column)" IS NOT NULL AND typeof("\(column)") = 'text'
                """)
            let hits = values.filter { v in
                let range = NSRange(v.startIndex..<v.endIndex, in: v)
                return regexes.contains { $0.firstMatch(in: v, range: range) != nil }
            }.count
            if hits > 0 { out["\(table).\(column)"] = hits }
        }
        return out
    }
}
