import Foundation
import GRDB
import TidyCore

extension AppDatabase {
    // MARK: entity_signals

    /// Insert a signal if one with the same (type, value) doesn't already exist.
    public func insertSignalIfAbsent(_ signal: EntitySignal) throws {
        try writer.write { db in var s = signal; try s.insert(db, onConflict: .ignore) }
    }

    /// Bulk form — **one** transaction for the whole batch.
    ///
    /// The bootstrap mints ~1,200 signals on a real workspace. Inserting them one at a time is
    /// ~1,200 separate write transactions, and the bootstrap runs on the pipeline cadence, so that
    /// cost repeats forever to re-insert rows that already exist. Same `onConflict: .ignore`
    /// semantics, so a `user_confirmed` row is still never overwritten.
    public func insertSignalsIfAbsent(_ signals: [EntitySignal]) throws {
        guard !signals.isEmpty else { return }
        try writer.write { db in
            for signal in signals { var s = signal; try s.insert(db, onConflict: .ignore) }
        }
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

    /// Resolve a possibly-stale suggestion id to the row that represents the same work NOW.
    ///
    /// The recap regenerates pending suggestions every 300s, so a card on screen can outlive the
    /// row behind it. Returning the id unchanged when it still exists, and otherwise the current row
    /// with the same **attribution identity**, is what makes "Log it ✓" and "Toss" work on a card
    /// the user has been looking at for more than one pass. Returning nil only when the work itself
    /// is gone from the day.
    public func liveSuggestionId(matching stale: Int64, day: String, attributionKey: String) throws -> Int64? {
        try writer.read { db in
            if try Suggestion.filter(sql: "id = ?", arguments: [stale]).fetchCount(db) > 0 { return stale }
            return try Suggestion.filter(sql: "day = ?", arguments: [day]).fetchAll(db)
                .first { Suggestion.attributionKey($0) == attributionKey }?.id
        }
    }

    /// Clear only the suggestions the user has NOT acted on, and return the keys of the ones kept.
    ///
    /// The pipeline regenerates every 300s. `clearDay` deletes and reinserts everything, so a
    /// suggestion marked Logged or Tossed reverts to `pending` and reappears within five minutes —
    /// the core loop of the product silently undoing itself. It also NULLs `decisions.suggestion_id`
    /// (the FK is `onDelete: .setNull`), orphaning the audit trail the learning loop reads.
    ///
    /// The returned keys let the engine skip regenerating a group the user already settled. A key is
    /// `kind|client|project|task` — attribution identity, not row id, because the row is rebuilt.
    @discardableResult
    public func clearPendingSuggestions(day: String) throws -> Set<String> {
        try writer.write { db in
            let decided = try Suggestion
                .filter(sql: "day = ? AND status != 'pending'", arguments: [day])
                .fetchAll(db)
            try Suggestion.filter(sql: "day = ? AND status = 'pending'", arguments: [day]).deleteAll(db)
            // Pools are pure scratch for the rebuild and carry no user decision.
            try Pool.filter(sql: "day = ?", arguments: [day]).deleteAll(db)
            // Keyed on the WORK, not the kind — see Suggestion.workKey.
            return Set(decided.map(\.workKey))
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
    /// Rollups across an inclusive day range ("YYYY-MM-DD"), oldest first — the dashboard's input.
    public func rollups(from startDay: String, to endDay: String) throws -> [DailyRollup] {
        try writer.read { db in
            try DailyRollup
                .filter(sql: "day >= ? AND day <= ?", arguments: [startDay, endDay])
                .order(sql: "day ASC").fetchAll(db)
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
