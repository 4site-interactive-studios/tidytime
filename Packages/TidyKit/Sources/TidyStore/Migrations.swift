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
        registerV1Capture(&m)
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

    private static func registerV1Capture(_ m: inout DatabaseMigrator) {
        m.registerMigration("v1-capture") { db in
            try db.create(table: "activity_samples") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("started_at", .integer).notNull().indexed()
                t.column("ended_at", .integer)
                t.column("app_bundle_id", .text).notNull().indexed()
                t.column("app_name", .text).notNull()
                t.column("window_title", .text)
                t.column("is_browser", .integer).notNull().defaults(to: 0)
                t.column("browser", .text)
                t.column("url", .text)
                t.column("source", .text).notNull()
                t.column("created_at", .integer).notNull()
            }
            try db.create(table: "page_snapshots") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sample_id", .integer).notNull()
                    .references("activity_samples", onDelete: .cascade)
                t.column("captured_at", .integer).notNull()
                t.column("url", .text).notNull()
                t.column("title", .text)
                t.column("content_hash", .text).notNull().indexed()
                t.column("text", .text).notNull()
                t.column("text_bytes", .integer).notNull()
            }
            // NOTE: sessions/away_gaps carry client_id/project_id/task_id, which reference
            // pd_* tables that don't exist until Phase 2. Per data-model.md, these are plain
            // columns here (no REFERENCES) to keep the migration order valid across phases.
            try db.create(table: "sessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("started_at", .integer).notNull().indexed()
                t.column("ended_at", .integer).notNull()
                t.column("duration_seconds", .integer).notNull()
                t.column("title", .text)
                t.column("context_key", .text)
                t.column("primary_app", .text)
                t.column("source_ref", .text)
                t.column("client_id", .text)
                t.column("project_id", .text)
                t.column("task_id", .text)
                t.column("confidence", .double)
                t.column("produced_by_rung", .integer)
                t.column("rationale", .text)
                t.column("is_sensitive", .integer).notNull().defaults(to: 0)
                t.column("classified_at", .integer)
                t.column("created_at", .integer).notNull()
            }
            try db.create(table: "away_gaps") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("started_at", .integer).notNull().indexed()
                t.column("ended_at", .integer).notNull()
                t.column("duration_seconds", .integer).notNull()
                t.column("cause", .text).notNull()
                t.column("attribution", .text)
                t.column("note", .text)
                t.column("client_id", .text)
                t.column("project_id", .text)
                t.column("resolved_at", .integer)
                t.column("created_at", .integer).notNull()
            }
            try db.create(table: "sync_state") { t in
                t.primaryKey("source", .text)
                t.column("cursor", .text)
                t.column("last_run_at", .integer)
                t.column("last_success_at", .integer)
                t.column("last_error", .text)
            }
        }
    }
}
