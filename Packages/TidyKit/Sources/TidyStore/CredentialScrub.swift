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
/// **Every TEXT column is redacted, discovered from the schema, not listed.** The first cut listed
/// six columns by judgement and reasoned that derived ones (`sessions.title`, `suggestions.note`)
/// are rebuilt — but only *today* is rebuilt, and a session built last month from a token-bearing
/// window title keeps the token forever. `Redactor` is shape-based and over-redaction is safe, so
/// there is no column it is wrong to run over. The same discovered list feeds `violations`, so the
/// purge and the check cannot disagree.
public enum CredentialScrub {
    /// URL columns, scrubbed with `URLScrubber` rather than redacted; a `.drop` deletes the row.
    /// Snapshots first, so a dropped snapshot is counted explicitly rather than disappearing
    /// through the `ON DELETE CASCADE` from its sample.
    public static let urlColumns: [(table: String, column: String)] = [
        ("page_snapshots", "url"),
        ("activity_samples", "url"),
    ]

    /// Tables that hold no external text and are skipped by the redaction pass.
    static let internalTables: Set<String> = ["app_metadata", "grdb_migrations"]

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
                    // Explicit, not via cascade: GRDB runs a migration with foreign keys OFF and
                    // checks them before commit, so an orphaned child would abort the migration —
                    // and with it every launch of the app (review finding, verified live).
                    if table == "activity_samples", tables.contains("page_snapshots") {
                        try db.execute(sql: "DELETE FROM page_snapshots WHERE sample_id = ?", arguments: [id])
                        report.rowsDropped += db.changesCount
                    }
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

        let urlColumnNames = Set(urlColumns.map { "\($0.table).\($0.column)" })
        for (table, column) in try textColumns(db)
        where !urlColumnNames.contains("\(table).\(column)") && !internalTables.contains(table) {
            // Prefilter on the literal anchors every redactor pattern needs, so the regexes run on
            // the few rows that can match rather than every window title ever recorded.
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT rowid AS rid, "\(column)" AS v FROM "\(table)"
                WHERE "\(column)" IS NOT NULL AND typeof("\(column)") = 'text' AND (\(anchorPredicate(column)))
                """)
            while let row = try cursor.next() {
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

    static func anchorPredicate(_ column: String) -> String {
        Redactor.anchors.map { "\"\(column)\" LIKE '%\($0.replacingOccurrences(of: "'", with: "''"))%'" }
            .joined(separator: " OR ")
    }

    /// Every TEXT-affinity column in the schema, for the purge and the guardrail scan. Discovered,
    /// not listed, so a new table is covered the day it is created.
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

    /// Count of stored values the redactor would still change, per `table.column`. Empty means
    /// clean. One definition of "clean" — the redactor's — so the scan can never report a violation
    /// the purge cannot clear (the first cut had its own pattern list and did exactly that).
    /// URL columns are checked for a credential-shaped query key, the thing the scrubber removes.
    public static func violations(_ db: Database) throws -> [String: Int] {
        var out: [String: Int] = [:]
        let urlColumnNames = Set(urlColumns.map { "\($0.table).\($0.column)" })
        for (table, column) in try textColumns(db) where !internalTables.contains(table) {
            let values = try String.fetchAll(db, sql: """
                SELECT "\(column)" FROM "\(table)" WHERE "\(column)" IS NOT NULL AND typeof("\(column)") = 'text'
                """)
            let isURL = urlColumnNames.contains("\(table).\(column)")
            let hits = values.filter { v in
                if isURL, let comps = URLComponents(string: v), URLScrubber.carriesCredentialKey(comps) { return true }
                return Redactor.redact(v) != v
            }.count
            if hits > 0 { out["\(table).\(column)"] = hits }
        }
        return out
    }
}
