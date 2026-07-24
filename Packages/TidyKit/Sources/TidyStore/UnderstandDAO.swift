import Foundation
import GRDB
import TidyCore

extension AppDatabase {
    // MARK: entity_signals

    /// Insert a signal if one with the same (type, value) doesn't already exist.
    public func insertSignalIfAbsent(_ signal: EntitySignal) throws {
        try writer.write { db in var s = signal; try s.insert(db, onConflict: .ignore) }
    }

    /// Create or strengthen a signal. A `user_confirmed` provenance upgrades an existing row and
    /// overwrites its attribution (user rules outrank inferred ones).
    public func strengthenSignal(type: String, value: String, clientId: String?, projectId: String?,
                                 provenance: String, now: Int64) throws {
        try writer.write { db in
            if var existing = try EntitySignal
                .filter(sql: "signal_type = ? AND signal_value = ?", arguments: [type, value]).fetchOne(db) {
                existing.hitCount += 1
                existing.weight += 0.5
                existing.lastSeenAt = now
                existing.updatedAt = now
                if provenance == "user_confirmed" {
                    existing.provenance = "user_confirmed"
                    existing.clientId = clientId ?? existing.clientId
                    existing.projectId = projectId ?? existing.projectId
                }
                try existing.update(db)
            } else {
                var s = EntitySignal(signalType: type, signalValue: value, clientId: clientId,
                                     projectId: projectId, provenance: provenance, weight: 1.0,
                                     hitCount: 1, lastSeenAt: now, createdAt: now, updatedAt: now)
                try s.insert(db)
            }
        }
    }

    public func signals(values: [String]) throws -> [EntitySignal] {
        guard !values.isEmpty else { return [] }
        return try writer.read { db in
            let placeholders = databaseQuestionMarks(count: values.count)
            return try EntitySignal
                .filter(sql: "signal_value IN (\(placeholders))", arguments: StatementArguments(values))
                .fetchAll(db)
        }
    }

    public func allSignals() throws -> [EntitySignal] {
        try writer.read { db in try EntitySignal.fetchAll(db) }
    }

    // MARK: sessions classification

    public func classifySession(id: Int64, clientId: String?, projectId: String?, taskId: String?,
                                confidence: Double, rung: Int, rationale: String?, classifiedAt: Int64) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE sessions SET client_id = ?, project_id = ?, task_id = ?, confidence = ?,
                    produced_by_rung = ?, rationale = ?, classified_at = ? WHERE id = ?
                """, arguments: [clientId, projectId, taskId, confidence, rung, rationale, classifiedAt, id])
        }
    }

    // MARK: suggestions

    @discardableResult
    public func insertSuggestion(_ suggestion: Suggestion) throws -> Int64 {
        try writer.write { db in var s = suggestion; try s.insert(db); return s.id! }
    }
    public func suggestions(day: String) throws -> [Suggestion] {
        try writer.read { db in
            try Suggestion.filter(sql: "day = ?", arguments: [day]).order(sql: "confidence DESC").fetchAll(db)
        }
    }
    public func updateSuggestionStatus(id: Int64, status: String, now: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE suggestions SET status = ?, updated_at = ? WHERE id = ?",
                           arguments: [status, now, id])
        }
    }
    /// Remove all suggestions + pools for a day (recap regenerates them).
    public func clearDay(_ day: String) throws {
        try writer.write { db in
            try Suggestion.filter(sql: "day = ?", arguments: [day]).deleteAll(db)
            try Pool.filter(sql: "day = ?", arguments: [day]).deleteAll(db)
        }
    }

    // MARK: decisions

    @discardableResult
    public func insertDecision(_ decision: Decision) throws -> Int64 {
        try writer.write { db in var d = decision; try d.insert(db); return d.id! }
    }
    public func decisions() throws -> [Decision] {
        try writer.read { db in try Decision.order(sql: "created_at DESC").fetchAll(db) }
    }

    // MARK: pools

    @discardableResult
    public func insertPool(_ pool: Pool) throws -> Int64 {
        try writer.write { db in var p = pool; try p.insert(db); return p.id! }
    }
    public func pools(day: String) throws -> [Pool] {
        try writer.read { db in try Pool.filter(sql: "day = ?", arguments: [day]).fetchAll(db) }
    }

    // MARK: resolution questions

    public func upsertQuestion(_ q: ResolutionQuestion) throws {
        try writer.write { db in var qq = q; try qq.insert(db, onConflict: .ignore) }
    }
    public func openQuestions() throws -> [ResolutionQuestion] {
        try writer.read { db in
            try ResolutionQuestion.filter(sql: "status = 'open'").order(sql: "created_at ASC").fetchAll(db)
        }
    }
    public func answerQuestion(signalType: String, signalValue: String, clientId: String?, projectId: String?, now: Int64) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE resolution_questions SET status = 'answered', answer_client_id = ?,
                    answer_project_id = ?, answered_at = ? WHERE signal_type = ? AND signal_value = ?
                """, arguments: [clientId, projectId, now, signalType, signalValue])
        }
    }

    // MARK: daily rollups

    public func upsertRollup(_ rollup: DailyRollup) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM daily_rollups WHERE day = ?", arguments: [rollup.day])
            var r = rollup; try r.insert(db)
        }
    }
    public func rollup(day: String) throws -> DailyRollup? {
        try writer.read { db in try DailyRollup.filter(sql: "day = ?", arguments: [day]).fetchOne(db) }
    }
}

/// `?,?,?` for an IN clause.
func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}
