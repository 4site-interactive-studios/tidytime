import Foundation
import GRDB

/// Phase 4: a captured Slack message. `UNIQUE(conversation_id, ts)` so re-sync is idempotent.
public struct SlackMessage: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "slack_messages"
    public var id: Int64?
    public var conversationId: String
    public var conversationType: String   // 'channel' | 'group' | 'im' | 'mpim'
    public var conversationName: String?
    public var ts: String
    public var postedAt: Int64
    public var userId: String?
    public var userName: String?
    public var isSelf: Bool
    public var threadTs: String?
    public var text: String?
    public var permalink: String?
    public var fetchedAt: Int64

    public init(id: Int64? = nil, conversationId: String, conversationType: String,
                conversationName: String? = nil, ts: String, postedAt: Int64, userId: String? = nil,
                userName: String? = nil, isSelf: Bool = false, threadTs: String? = nil,
                text: String? = nil, permalink: String? = nil, fetchedAt: Int64) {
        self.id = id; self.conversationId = conversationId; self.conversationType = conversationType
        self.conversationName = conversationName; self.ts = ts; self.postedAt = postedAt
        self.userId = userId; self.userName = userName; self.isSelf = isSelf; self.threadTs = threadTs
        self.text = text; self.permalink = permalink; self.fetchedAt = fetchedAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    enum CodingKeys: String, CodingKey {
        case id, conversationId = "conversation_id", conversationType = "conversation_type"
        case conversationName = "conversation_name", ts, postedAt = "posted_at"
        case userId = "user_id", userName = "user_name", isSelf = "is_self", threadTs = "thread_ts"
        case text, permalink, fetchedAt = "fetched_at"
    }
}
