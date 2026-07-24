import Foundation
import GRDB

// Phase 5 records: entity_signals, pools, suggestions, decisions, resolution_questions,
// daily_rollups. Column names match docs/architecture/data-model.md.

public struct EntitySignal: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "entity_signals"
    public var id: Int64?
    public var signalType: String
    public var signalValue: String
    public var clientId: String?
    public var projectId: String?
    public var provenance: String    // 'bootstrapped' | 'inferred' | 'user_confirmed'
    public var weight: Double
    public var hitCount: Int
    public var lastSeenAt: Int64?
    public var createdAt: Int64
    public var updatedAt: Int64
    public init(id: Int64? = nil, signalType: String, signalValue: String, clientId: String? = nil,
                projectId: String? = nil, provenance: String, weight: Double = 1.0, hitCount: Int = 0,
                lastSeenAt: Int64? = nil, createdAt: Int64, updatedAt: Int64) {
        self.id = id; self.signalType = signalType; self.signalValue = signalValue
        self.clientId = clientId; self.projectId = projectId; self.provenance = provenance
        self.weight = weight; self.hitCount = hitCount; self.lastSeenAt = lastSeenAt
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    /// User-confirmed rules outrank inferred ones (docs: understand-layer).
    public var isAuthoritative: Bool { provenance == "user_confirmed" }
    enum CodingKeys: String, CodingKey {
        case id, signalType = "signal_type", signalValue = "signal_value", clientId = "client_id"
        case projectId = "project_id", provenance, weight, hitCount = "hit_count"
        case lastSeenAt = "last_seen_at", createdAt = "created_at", updatedAt = "updated_at"
    }
}

public struct Suggestion: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "suggestions"
    public var id: Int64?
    public var day: String
    public var kind: String           // 'session'|'pool'|'meeting_segment'|'away'|'new_task'
    public var clientId: String?
    public var projectId: String?
    public var taskId: String?
    public var proposedTaskTitle: String?
    public var proposedTaskDescription: String?
    public var minutes: Int
    public var rawSeconds: Int
    public var billable: Bool?
    public var note: String?
    public var confidence: Double
    public var producedByRung: Int
    public var rationale: String?
    public var isRoundedUp: Bool
    public var isSensitive: Bool
    public var deepLink: String?
    public var status: String         // 'pending'|'logged'|'edited'|'reassigned'|'tossed'|'snoozed'
    public var sourceRefsJson: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public init(id: Int64? = nil, day: String, kind: String, clientId: String? = nil,
                projectId: String? = nil, taskId: String? = nil, proposedTaskTitle: String? = nil,
                proposedTaskDescription: String? = nil, minutes: Int, rawSeconds: Int, billable: Bool? = nil,
                note: String? = nil, confidence: Double, producedByRung: Int, rationale: String? = nil,
                isRoundedUp: Bool = false, isSensitive: Bool = false, deepLink: String? = nil,
                status: String = "pending", sourceRefsJson: String = "{}", createdAt: Int64, updatedAt: Int64) {
        self.id = id; self.day = day; self.kind = kind; self.clientId = clientId; self.projectId = projectId
        self.taskId = taskId; self.proposedTaskTitle = proposedTaskTitle; self.proposedTaskDescription = proposedTaskDescription
        self.minutes = minutes; self.rawSeconds = rawSeconds; self.billable = billable; self.note = note
        self.confidence = confidence; self.producedByRung = producedByRung; self.rationale = rationale
        self.isRoundedUp = isRoundedUp; self.isSensitive = isSensitive; self.deepLink = deepLink
        self.status = status; self.sourceRefsJson = sourceRefsJson; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    enum CodingKeys: String, CodingKey {
        case id, day, kind, clientId = "client_id", projectId = "project_id", taskId = "task_id"
        case proposedTaskTitle = "proposed_task_title", proposedTaskDescription = "proposed_task_description"
        case minutes, rawSeconds = "raw_seconds", billable, note, confidence, producedByRung = "produced_by_rung"
        case rationale, isRoundedUp = "is_rounded_up", isSensitive = "is_sensitive", deepLink = "deep_link"
        case status, sourceRefsJson = "source_refs_json", createdAt = "created_at", updatedAt = "updated_at"
    }
}

public struct Decision: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "decisions"
    public var id: Int64?
    public var suggestionId: Int64?
    public var action: String        // 'accept'|'edit'|'reassign'|'toss'|'log'|'snooze'
    public var beforeJson: String?
    public var afterJson: String?
    public var clientId: String?
    public var projectId: String?
    public var taskId: String?
    public var note: String?
    public var createdAt: Int64
    public init(id: Int64? = nil, suggestionId: Int64? = nil, action: String, beforeJson: String? = nil,
                afterJson: String? = nil, clientId: String? = nil, projectId: String? = nil,
                taskId: String? = nil, note: String? = nil, createdAt: Int64) {
        self.id = id; self.suggestionId = suggestionId; self.action = action; self.beforeJson = beforeJson
        self.afterJson = afterJson; self.clientId = clientId; self.projectId = projectId; self.taskId = taskId
        self.note = note; self.createdAt = createdAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    enum CodingKeys: String, CodingKey {
        case id, suggestionId = "suggestion_id", action, beforeJson = "before_json", afterJson = "after_json"
        case clientId = "client_id", projectId = "project_id", taskId = "task_id", note, createdAt = "created_at"
    }
}

public struct Pool: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "pools"
    public var id: Int64?
    public var day: String
    public var clientId: String?
    public var projectId: String?
    public var accumulatedSeconds: Int
    public var itemCount: Int
    public var itemsJson: String
    public var status: String        // 'open'|'rolled_up'|'suggested'
    public var suggestionId: Int64?
    public var createdAt: Int64
    public var updatedAt: Int64
    public init(id: Int64? = nil, day: String, clientId: String? = nil, projectId: String? = nil,
                accumulatedSeconds: Int = 0, itemCount: Int = 0, itemsJson: String = "[]",
                status: String = "open", suggestionId: Int64? = nil, createdAt: Int64, updatedAt: Int64) {
        self.id = id; self.day = day; self.clientId = clientId; self.projectId = projectId
        self.accumulatedSeconds = accumulatedSeconds; self.itemCount = itemCount; self.itemsJson = itemsJson
        self.status = status; self.suggestionId = suggestionId; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    enum CodingKeys: String, CodingKey {
        case id, day, clientId = "client_id", projectId = "project_id"
        case accumulatedSeconds = "accumulated_seconds", itemCount = "item_count", itemsJson = "items_json"
        case status, suggestionId = "suggestion_id", createdAt = "created_at", updatedAt = "updated_at"
    }
}

public struct ResolutionQuestion: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "resolution_questions"
    public var id: Int64?
    public var question: String
    public var signalType: String
    public var signalValue: String
    public var status: String        // 'open'|'answered'|'dismissed'
    public var answerClientId: String?
    public var answerProjectId: String?
    public var createdAt: Int64
    public var answeredAt: Int64?
    public init(id: Int64? = nil, question: String, signalType: String, signalValue: String,
                status: String = "open", answerClientId: String? = nil, answerProjectId: String? = nil,
                createdAt: Int64, answeredAt: Int64? = nil) {
        self.id = id; self.question = question; self.signalType = signalType; self.signalValue = signalValue
        self.status = status; self.answerClientId = answerClientId; self.answerProjectId = answerProjectId
        self.createdAt = createdAt; self.answeredAt = answeredAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    enum CodingKeys: String, CodingKey {
        case id, question, signalType = "signal_type", signalValue = "signal_value", status
        case answerClientId = "answer_client_id", answerProjectId = "answer_project_id"
        case createdAt = "created_at", answeredAt = "answered_at"
    }
}

public struct DailyRollup: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "daily_rollups"
    public var id: Int64?
    public var day: String
    public var observedSeconds: Int
    public var attributedSeconds: Int
    public var loggedMinutes: Int
    public var billableMinutes: Int
    public var internalMinutes: Int
    public var perClientJson: String
    public var captureHealth: Double?
    public var aiCostUsd: Double
    public var createdAt: Int64
    public var updatedAt: Int64
    public init(id: Int64? = nil, day: String, observedSeconds: Int = 0, attributedSeconds: Int = 0,
                loggedMinutes: Int = 0, billableMinutes: Int = 0, internalMinutes: Int = 0,
                perClientJson: String = "{}", captureHealth: Double? = nil, aiCostUsd: Double = 0,
                createdAt: Int64, updatedAt: Int64) {
        self.id = id; self.day = day; self.observedSeconds = observedSeconds; self.attributedSeconds = attributedSeconds
        self.loggedMinutes = loggedMinutes; self.billableMinutes = billableMinutes; self.internalMinutes = internalMinutes
        self.perClientJson = perClientJson; self.captureHealth = captureHealth; self.aiCostUsd = aiCostUsd
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    enum CodingKeys: String, CodingKey {
        case id, day, observedSeconds = "observed_seconds", attributedSeconds = "attributed_seconds"
        case loggedMinutes = "logged_minutes", billableMinutes = "billable_minutes", internalMinutes = "internal_minutes"
        case perClientJson = "per_client_json", captureHealth = "capture_health", aiCostUsd = "ai_cost_usd"
        case createdAt = "created_at", updatedAt = "updated_at"
    }
}
