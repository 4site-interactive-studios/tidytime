import Foundation
import GRDB
import TidyCore

extension AppDatabase {
    /// Upsert Slack messages (idempotent on the `(conversation_id, ts)` unique key).
    public func upsertSlackMessages(_ messages: [SlackMessage]) throws {
        try writer.write { db in
            for var msg in messages { try msg.insert(db, onConflict: .replace) }
        }
    }

    public func slackMessages(conversationId: String) throws -> [SlackMessage] {
        try writer.read { db in
            try SlackMessage
                .filter(sql: "conversation_id = ?", arguments: [conversationId])
                .order(sql: "posted_at ASC").fetchAll(db)
        }
    }

    public func slackMessages(from start: Int64, to end: Int64) throws -> [SlackMessage] {
        try writer.read { db in
            try SlackMessage
                .filter(sql: "posted_at >= ? AND posted_at < ?", arguments: [start, end])
                .order(sql: "posted_at ASC").fetchAll(db)
        }
    }

    /// Latest message ts stored for a conversation — the incremental `oldest` cursor.
    public func latestSlackTs(conversationId: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql:
                "SELECT ts FROM slack_messages WHERE conversation_id = ? ORDER BY posted_at DESC LIMIT 1",
                arguments: [conversationId])
        }
    }

    /// Fill in display names for messages stored while the users.list throttle was active —
    /// their rows would otherwise stay nameless forever (the cursor never re-fetches them).
    public func backfillSlackUserNames(_ names: [String: String]) throws {
        guard !names.isEmpty else { return }
        try writer.write { db in
            for (userId, name) in names {
                try db.execute(sql: """
                    UPDATE slack_messages SET user_name = ? WHERE user_id = ? AND user_name IS NULL
                    """, arguments: [name, userId])
            }
        }
    }

    /// Remove `kind='slack'` sessions for a conversation before rebuilding (idempotent re-sync).
    public func deleteSlackSessions(conversationId: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM sessions WHERE kind = 'slack' AND source_ref = ?",
                           arguments: [conversationId])
        }
    }
}
