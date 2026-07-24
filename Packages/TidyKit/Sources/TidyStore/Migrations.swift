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
        registerV1Productive(&m)
        registerV1Meetings(&m)
        registerV1Slack(&m)
        registerV1Understand(&m)
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

    private static func registerV1Productive(_ m: inout DatabaseMigrator) {
        m.registerMigration("v1-productive") { db in
            try db.create(table: "pd_companies") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("company_type", .text)
                t.column("domain", .text)
                t.column("archived", .integer).notNull().defaults(to: 0)
                t.column("synced_at", .integer).notNull()
            }
            try db.create(table: "pd_projects") { t in
                t.primaryKey("id", .text)
                t.column("company_id", .text).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("project_type_id", .integer)
                t.column("project_number", .text)
                t.column("archived", .integer).notNull().defaults(to: 0)
                t.column("synced_at", .integer).notNull()
            }
            try db.create(table: "pd_tasks") { t in
                t.primaryKey("id", .text)
                t.column("project_id", .text).notNull().indexed()
                t.column("task_list_id", .text)
                t.column("title", .text).notNull()
                t.column("description", .text)
                t.column("task_number", .integer)
                t.column("status", .text)
                t.column("closed", .integer).notNull().defaults(to: 0)
                t.column("assignee_id", .text).indexed()
                t.column("due_date", .text)
                t.column("synced_at", .integer).notNull()
            }
            try db.create(table: "pd_time_entries") { t in
                t.primaryKey("id", .text)
                t.column("person_id", .text).notNull()
                t.column("task_id", .text)
                t.column("project_id", .text)
                t.column("service_id", .text)
                t.column("date", .text).notNull()
                t.column("time_minutes", .integer).notNull()
                t.column("billable_minutes", .integer)
                t.column("note", .text)
                t.column("synced_at", .integer).notNull()
                // NOT unique on (person_id, date): a person logs many entries per day.
            }
            try db.create(indexOn: "pd_time_entries", columns: ["person_id", "date"])
            try db.create(table: "pd_people") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("email", .text)
                t.column("is_self", .integer).notNull().defaults(to: 0)
                t.column("synced_at", .integer).notNull()
            }
        }
    }

    private static func registerV1Meetings(_ m: inout DatabaseMigrator) {
        m.registerMigration("v1-meetings") { db in
            try db.create(table: "calendar_events") { t in
                t.primaryKey("id", .text)
                t.column("calendar_id", .text).notNull()
                t.column("title", .text)
                t.column("description", .text)
                t.column("location", .text)
                t.column("start_at", .integer).notNull().indexed()
                t.column("end_at", .integer).notNull()
                t.column("all_day", .integer).notNull().defaults(to: 0)
                t.column("status", .text)
                t.column("organizer_email", .text)
                t.column("attendees_json", .text)
                t.column("conference_url", .text)
                t.column("ical_uid", .text)
                t.column("updated_at", .integer)
                t.column("fetched_at", .integer).notNull()
            }
            try db.create(table: "meetings") { t in
                t.primaryKey("id", .text)
                t.column("source", .text).notNull()
                t.column("title", .text)
                t.column("scheduled_start", .integer)
                t.column("scheduled_end", .integer)
                t.column("recording_start", .integer)
                t.column("recording_end", .integer)
                t.column("duration_seconds", .integer).notNull()
                t.column("has_transcript", .integer).notNull().defaults(to: 0)
                t.column("has_summary", .integer).notNull().defaults(to: 0)
                t.column("summary", .text)
                t.column("external_url", .text)
                t.column("calendar_event_id", .text).references("calendar_events", onDelete: .setNull)
                t.column("fetched_at", .integer).notNull()
                t.column("created_at", .integer).notNull()
            }
            try db.create(table: "meeting_invitees") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull()
                    .references("meetings", onDelete: .cascade).indexed()
                t.column("email", .text)
                t.column("name", .text)
                t.column("email_domain", .text).indexed()
                t.column("is_external", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "transcript_utterances") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meeting_id", .text).notNull()
                    .references("meetings", onDelete: .cascade)
                t.column("idx", .integer).notNull()
                t.column("speaker", .text)
                t.column("speaker_email", .text)
                t.column("start_seconds", .double).notNull()
                t.column("end_seconds", .double)
                t.column("text", .text).notNull()
            }
            try db.create(indexOn: "transcript_utterances", columns: ["meeting_id", "idx"])
        }
    }

    private static func registerV1Slack(_ m: inout DatabaseMigrator) {
        m.registerMigration("v1-slack") { db in
            try db.create(table: "slack_messages") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversation_id", .text).notNull().indexed()
                t.column("conversation_type", .text).notNull()
                t.column("conversation_name", .text)
                t.column("ts", .text).notNull()
                t.column("posted_at", .integer).notNull().indexed()
                t.column("user_id", .text)
                t.column("user_name", .text)
                t.column("is_self", .integer).notNull().defaults(to: 0)
                t.column("thread_ts", .text)
                t.column("text", .text)
                t.column("permalink", .text)
                t.column("fetched_at", .integer).notNull()
                t.uniqueKey(["conversation_id", "ts"])
            }
        }
    }

    private static func registerV1Understand(_ m: inout DatabaseMigrator) {
        m.registerMigration("v1-understand") { db in
            try db.create(table: "entity_signals") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("signal_type", .text).notNull()
                t.column("signal_value", .text).notNull().indexed()
                t.column("client_id", .text)
                t.column("project_id", .text)
                t.column("provenance", .text).notNull()
                t.column("weight", .double).notNull().defaults(to: 1.0)
                t.column("hit_count", .integer).notNull().defaults(to: 0)
                t.column("last_seen_at", .integer)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
                t.uniqueKey(["signal_type", "signal_value"])
            }
            try db.create(table: "suggestions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("day", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("client_id", .text)
                t.column("project_id", .text)
                t.column("task_id", .text)
                t.column("proposed_task_title", .text)
                t.column("proposed_task_description", .text)
                t.column("minutes", .integer).notNull()
                t.column("raw_seconds", .integer).notNull()
                t.column("billable", .integer)
                t.column("note", .text)
                t.column("confidence", .double).notNull()
                t.column("produced_by_rung", .integer).notNull()
                t.column("rationale", .text)
                t.column("is_rounded_up", .integer).notNull().defaults(to: 0)
                t.column("is_sensitive", .integer).notNull().defaults(to: 0)
                t.column("deep_link", .text)
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("source_refs_json", .text).notNull().defaults(to: "{}")
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
            }
            try db.create(indexOn: "suggestions", columns: ["day", "status"])
            try db.create(table: "decisions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("suggestion_id", .integer).references("suggestions", onDelete: .setNull)
                t.column("action", .text).notNull()
                t.column("before_json", .text)
                t.column("after_json", .text)
                t.column("client_id", .text)
                t.column("project_id", .text)
                t.column("task_id", .text)
                t.column("note", .text)
                t.column("created_at", .integer).notNull().indexed()
            }
            try db.create(table: "pools") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("day", .text).notNull().indexed()
                t.column("client_id", .text)
                t.column("project_id", .text)
                t.column("accumulated_seconds", .integer).notNull().defaults(to: 0)
                t.column("item_count", .integer).notNull().defaults(to: 0)
                t.column("items_json", .text).notNull().defaults(to: "[]")
                t.column("status", .text).notNull().defaults(to: "open")
                t.column("suggestion_id", .integer)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
            }
            try db.create(table: "resolution_questions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("question", .text).notNull()
                t.column("signal_type", .text).notNull()
                t.column("signal_value", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "open")
                t.column("answer_client_id", .text)
                t.column("answer_project_id", .text)
                t.column("created_at", .integer).notNull()
                t.column("answered_at", .integer)
                t.uniqueKey(["signal_type", "signal_value"])
            }
            try db.create(table: "daily_rollups") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("day", .text).notNull().unique()
                t.column("observed_seconds", .integer).notNull().defaults(to: 0)
                t.column("attributed_seconds", .integer).notNull().defaults(to: 0)
                t.column("logged_minutes", .integer).notNull().defaults(to: 0)
                t.column("billable_minutes", .integer).notNull().defaults(to: 0)
                t.column("internal_minutes", .integer).notNull().defaults(to: 0)
                t.column("per_client_json", .text).notNull().defaults(to: "{}")
                t.column("capture_health", .double)
                t.column("ai_cost_usd", .double).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
            }
        }
    }
}
