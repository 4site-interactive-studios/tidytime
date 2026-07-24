import Foundation
import GRDB
import TidyCore

extension AppDatabase {
    // MARK: ai_calls ledger

    @discardableResult
    public func insertAICall(_ call: AICall) throws -> Int64 {
        try writer.write { db in var c = call; try c.insert(db); return c.id! }
    }

    /// Total cost in a window, optionally for one provider.
    public func aiCost(from: Int64, to: Int64, provider: String? = nil) throws -> Double {
        try writer.read { db in
            if let provider {
                return try Double.fetchOne(db, sql:
                    "SELECT COALESCE(SUM(cost_usd),0) FROM ai_calls WHERE occurred_at >= ? AND occurred_at < ? AND provider = ?",
                    arguments: [from, to, provider]) ?? 0
            }
            return try Double.fetchOne(db, sql:
                "SELECT COALESCE(SUM(cost_usd),0) FROM ai_calls WHERE occurred_at >= ? AND occurred_at < ?",
                arguments: [from, to]) ?? 0
        }
    }

    public func aiCalls(from: Int64, to: Int64) throws -> [AICall] {
        try writer.read { db in
            try AICall.filter(sql: "occurred_at >= ? AND occurred_at < ?", arguments: [from, to])
                .order(sql: "occurred_at ASC").fetchAll(db)
        }
    }

    // MARK: nudges

    @discardableResult
    public func insertNudge(_ nudge: NudgeRecord) throws -> Int64 {
        try writer.write { db in var n = nudge; try n.insert(db); return n.id! }
    }

    public func nudgeCount(from: Int64, to: Int64) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM nudges WHERE fired_at >= ? AND fired_at < ?",
                             arguments: [from, to]) ?? 0
        }
    }

    /// How many times a context was dismissed/ignored — raises its nudge threshold.
    public func nudgeDismissals(contextKey: String) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM nudges WHERE context_key = ? AND outcome IN ('dismissed','ignored')",
                arguments: [contextKey]) ?? 0
        }
    }

    public func setNudgeOutcome(id: Int64, outcome: String, now: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE nudges SET outcome = ?, responded_at = ? WHERE id = ?",
                           arguments: [outcome, now, id])
        }
    }
}
