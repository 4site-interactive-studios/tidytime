import Foundation
import GRDB
import TidyCore

/// Owns the SQLite connection and applies migrations on open. Wraps a GRDB `DatabaseWriter`
/// (`DatabasePool` on disk with WAL; `DatabaseQueue` in memory for tests).
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    /// On-disk path, or nil for an in-memory database. For diagnostics/doctor.
    public let path: String?

    /// Create from an existing writer, running migrations. Used by both `open` and `inMemory`.
    public init(_ writer: any DatabaseWriter, path: String? = nil) throws {
        self.writer = writer
        self.path = path
        do {
            try Migrations.migrator().migrate(writer)
        } catch {
            throw TidyError.database("migration failed: \(error)")
        }
    }

    /// Open the on-disk database at `url` (WAL, foreign keys on, 5s busy timeout).
    public static func open(at url: URL) throws -> AppDatabase {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let pool = try DatabasePool(path: url.path, configuration: config)
            return try AppDatabase(pool, path: url.path)
        } catch let e as TidyError {
            throw e
        } catch {
            throw TidyError.database("open failed at \(url.path): \(error)")
        }
    }

    /// In-memory database for tests (fast, isolated, foreign keys on).
    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        return try AppDatabase(queue)
    }

    // MARK: - Diagnostics helpers

    /// Row counts for every user table — feeds the diagnostic bundle without dumping user data.
    public func tableRowCounts() throws -> [String: Int] {
        try writer.read { db in
            let names = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                ORDER BY name
                """)
            var out: [String: Int] = [:]
            for n in names {
                out[n] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(n)\"") ?? 0
            }
            return out
        }
    }

    /// Applied migration identifiers, newest last.
    public func appliedMigrations() throws -> [String] {
        try writer.read { db in try Migrations.migrator().appliedIdentifiers(db).sorted() }
    }
}
