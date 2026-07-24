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
