import Foundation
import GRDB
import TidyCore

/// Row of `app_metadata` (key/value bookkeeping).
public struct AppMetadata: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "app_metadata"
    public var key: String
    public var value: String
    public var updatedAt: Int64

    public init(key: String, value: String, updatedAt: Int64) {
        self.key = key; self.value = value; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case key, value, updatedAt = "updated_at" }
}

/// Well-known metadata keys.
public enum MetadataKey {
    public static let installId = "install_id"
    public static let schemaVersion = "schema_version"
    /// Provenance of the build that most recently opened this database, as
    /// `BuildInfo.summary` — `0.1.0 (8dda588, built 2026-07-27T12:53:16Z)`.
    public static let lastRunBuild = "last_run_build"
    /// Filesystem path of the bundle that most recently opened this database. Deliberately
    /// separate from ``lastRunBuild``: two identical builds in different locations are the case
    /// that fooled a live debugging session, and only the path tells them apart.
    public static let lastRunBundlePath = "last_run_bundle_path"
}

extension AppDatabase {
    /// Record which build just opened the database. Written on every launch so the *database*
    /// — readable by `tidytime-doctor` with the app closed — always knows what last ran against
    /// it. Best-effort: provenance bookkeeping must never block startup.
    public func recordRunningBuild(_ build: BuildInfo, clock: TidyClock = SystemClock()) {
        try? setMetadata(MetadataKey.lastRunBuild, build.summary, clock: clock)
        try? setMetadata(MetadataKey.lastRunBundlePath, build.bundlePath, clock: clock)
    }
}

extension AppDatabase {
    /// Read a metadata value.
    public func metadata(_ key: String) throws -> String? {
        try writer.read { db in try AppMetadata.fetchOne(db, key: key)?.value }
    }

    /// Upsert a metadata value, stamping `updated_at` from the clock.
    public func setMetadata(_ key: String, _ value: String, clock: TidyClock = SystemClock()) throws {
        let row = AppMetadata(key: key, value: value, updatedAt: Int64(clock.now.timeIntervalSince1970))
        try writer.write { db in try row.save(db) }
    }

    /// Return the stable install id, creating it on first call.
    @discardableResult
    public func installId(clock: TidyClock = SystemClock(), makeId: () -> String = { UUID().uuidString }) throws -> String {
        if let existing = try metadata(MetadataKey.installId) { return existing }
        let id = makeId()
        try setMetadata(MetadataKey.installId, id, clock: clock)
        return id
    }
}
