import Foundation
import GRDB

/// Phase 6: the AI usage ledger row (guardrail G5 — every cloud call writes one).
public struct AICall: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "ai_calls"
    public var id: Int64?
    public var occurredAt: Int64
    public var jobType: String        // 'session_batch'|'transcript_split'|'note_draft'|'calibration'|'escalation'|'on_device_classify'
    public var provider: String       // 'apple'|'fireworks'|'anthropic'|'none'
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUsd: Double
    public var latencyMs: Int?
    public var outcome: String        // 'ok'|'retried'|'escalated'|'error'|'refused_budget'|'refused_sensitive'
    public var requestRef: String?
    public var error: String?
    public init(id: Int64? = nil, occurredAt: Int64, jobType: String, provider: String, model: String,
                inputTokens: Int = 0, outputTokens: Int = 0, costUsd: Double = 0, latencyMs: Int? = nil,
                outcome: String, requestRef: String? = nil, error: String? = nil) {
        self.id = id; self.occurredAt = occurredAt; self.jobType = jobType; self.provider = provider
        self.model = model; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.costUsd = costUsd; self.latencyMs = latencyMs; self.outcome = outcome
        self.requestRef = requestRef; self.error = error
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    enum CodingKeys: String, CodingKey {
        case id, occurredAt = "occurred_at", jobType = "job_type", provider, model
        case inputTokens = "input_tokens", outputTokens = "output_tokens", costUsd = "cost_usd"
        case latencyMs = "latency_ms", outcome, requestRef = "request_ref", error
    }
}

/// Phase 6: a fired nudge + its outcome (rate-limiting + learning input).
public struct NudgeRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "nudges"
    public var id: Int64?
    public var firedAt: Int64
    public var contextKey: String
    public var clientId: String?
    public var sessionId: Int64?
    public var suggestionId: Int64?
    public var outcome: String?       // 'accepted'|'snoozed'|'dismissed'|'ignored'
    public var respondedAt: Int64?
    public init(id: Int64? = nil, firedAt: Int64, contextKey: String, clientId: String? = nil,
                sessionId: Int64? = nil, suggestionId: Int64? = nil, outcome: String? = nil, respondedAt: Int64? = nil) {
        self.id = id; self.firedAt = firedAt; self.contextKey = contextKey; self.clientId = clientId
        self.sessionId = sessionId; self.suggestionId = suggestionId; self.outcome = outcome; self.respondedAt = respondedAt
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    enum CodingKeys: String, CodingKey {
        case id, firedAt = "fired_at", contextKey = "context_key", clientId = "client_id"
        case sessionId = "session_id", suggestionId = "suggestion_id", outcome, respondedAt = "responded_at"
    }
}
