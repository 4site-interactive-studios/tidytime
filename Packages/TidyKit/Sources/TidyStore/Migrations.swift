import Foundation
import GRDB

/// The GRDB migrator. One registered migration per schema change, applied in order, NEVER edited
/// once shipped (docs/architecture/data-model.md → Migrations). Later phases append migrations:
///   v1-core     (Phase 0) — app_metadata
///   v1-capture  (Phase 1) — activity_samples, page_snapshots, sessions, away_gaps, sync_state
///   v1-productive (Phase 2), v1-meetings (Phase 3), v1-slack (Phase 4),
///   v1-understand (Phase 5), v1-ai (Phase 6)
public enum Migrations {
    public static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        registerV1Core(&m)
        return m
    }

    private static func registerV1Core(_ m: inout DatabaseMigrator) {
        m.registerMigration("v1-core") { db in
            // Key/value app metadata: schema/install bookkeeping and simple persisted flags.
            try db.create(table: "app_metadata") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
                t.column("updated_at", .integer).notNull()
            }
        }
    }
}
