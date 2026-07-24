import Foundation
import TidyCore
import TidyStore

/// Turns a day's classified sessions into `suggestions` + `pools`:
///  - group by task → project → client,
///  - standalone groups (≥ threshold) become suggestions, rounded, gap-analyzed vs logged entries,
///  - sub-threshold groups pool per project and roll up into one itemized suggestion,
///  - a group with a client/project but no task becomes a new-task proposal.
public struct SuggestionEngine: Sendable {
    private let db: AppDatabase
    private let clock: TidyClock
    private let rounding: RoundingPolicy
    private let standaloneThresholdMinutes: Int
    private let poolThresholdMinutes: Int
    private let selfPersonId: String?

    public init(db: AppDatabase, clock: TidyClock = SystemClock(), rounding: RoundingPolicy = RoundingPolicy(),
                standaloneThresholdMinutes: Int = 15, poolThresholdMinutes: Int = 15, selfPersonId: String? = nil) {
        self.db = db; self.clock = clock; self.rounding = rounding
        self.standaloneThresholdMinutes = standaloneThresholdMinutes
        self.poolThresholdMinutes = poolThresholdMinutes; self.selfPersonId = selfPersonId
    }

    public struct Summary: Sendable, Equatable {
        public var standalone: Int
        public var pools: Int
        public var newTaskProposals: Int
        public var skippedAlreadyLogged: Int
    }

    private struct Group {
        var clientId: String
        var projectId: String?
        var taskId: String?
        var seconds: Int = 0
        var sessionIds: [Int64] = []
        var titles: [String] = []
        var confidence: Double = 0
        var rung: Int = 5
        var isMeeting = false
    }

    @discardableResult
    public func generate(day: String, from: Int64, to: Int64) throws -> Summary {
        try db.clearDay(day)
        let now = Int64(clock.now.timeIntervalSince1970)
        let sessions = try db.sessions(from: from, to: to)

        // Logged minutes per task (gap analysis input).
        var loggedByTask: [String: Int] = [:]
        if let personId = selfPersonId {
            for e in (try? db.timeEntries(personId: personId, date: day)) ?? [] {
                if let t = e.taskId { loggedByTask[t, default: 0] += e.timeMinutes }
            }
        }

        // Aggregate classified sessions into attribution groups.
        var groups: [String: Group] = [:]
        for s in sessions {
            guard let clientId = s.clientId else { continue }
            let key = s.taskId.map { "t:" + $0 } ?? s.projectId.map { "p:" + $0 } ?? "c:" + clientId
            var g = groups[key] ?? Group(clientId: clientId, projectId: s.projectId, taskId: s.taskId)
            g.seconds += s.durationSeconds
            if let id = s.id { g.sessionIds.append(id) }
            if let t = s.title, !t.isEmpty { g.titles.append(t) }
            g.confidence = max(g.confidence, s.confidence ?? 0)
            g.rung = min(g.rung, s.producedByRung ?? 5)
            if s.kind == "meeting" { g.isMeeting = true }
            groups[key] = g
        }

        var summary = Summary(standalone: 0, pools: 0, newTaskProposals: 0, skippedAlreadyLogged: 0)
        var pools: [String: Group] = [:]   // keyed by project/client for sub-threshold work

        for (_, g) in groups {
            let rawMinutes = g.seconds / 60
            if rawMinutes >= standaloneThresholdMinutes {
                let (minutes, roundedUp) = rounding.rounded(seconds: g.seconds)
                // Gap analysis: for a known task, only suggest what's not already logged.
                var suggestMinutes = minutes
                var rationaleExtra = ""
                if let taskId = g.taskId, let logged = loggedByTask[taskId], logged > 0 {
                    suggestMinutes = max(0, minutes - logged)
                    rationaleExtra = " (you logged \(logged)m; suggesting the remainder)"
                    if suggestMinutes == 0 { summary.skippedAlreadyLogged += 1; continue }
                }
                let kind: String
                if g.taskId != nil { kind = g.isMeeting ? "meeting_segment" : "session" }
                else { kind = "new_task"; summary.newTaskProposals += 1 }

                let suggestion = Suggestion(
                    day: day, kind: kind, clientId: g.clientId, projectId: g.projectId, taskId: g.taskId,
                    proposedTaskTitle: kind == "new_task" ? proposedTitle(g) : nil,
                    minutes: suggestMinutes, rawSeconds: g.seconds, note: note(for: g),
                    confidence: g.confidence, producedByRung: g.rung,
                    rationale: "grouped \(g.sessionIds.count) session(s)" + rationaleExtra,
                    isRoundedUp: roundedUp, sourceRefsJson: sourceRefs(g.sessionIds),
                    createdAt: now, updatedAt: now)
                try db.insertSuggestion(suggestion)
                summary.standalone += 1
            } else {
                let poolKey = g.projectId.map { "p:" + $0 } ?? "c:" + g.clientId
                var p = pools[poolKey] ?? Group(clientId: g.clientId, projectId: g.projectId)
                p.seconds += g.seconds
                p.sessionIds.append(contentsOf: g.sessionIds)
                p.titles.append(contentsOf: g.titles)
                p.confidence = max(p.confidence, g.confidence)
                p.rung = min(p.rung, g.rung)
                pools[poolKey] = p
            }
        }

        // At recap time, every non-empty pool rolls up into one itemized suggestion (the
        // `poolThresholdMinutes` is for real-time promotion during the day; at recap nothing is left
        // to evaporate). `generate` is the recap run, so roll up all pools with time on them.
        for (_, p) in pools where p.seconds > 0 {
            _ = poolThresholdMinutes  // retained for real-time promotion; unused at recap
            let (minutes, roundedUp) = rounding.rounded(seconds: p.seconds)
            let poolId = try db.insertPool(Pool(
                day: day, clientId: p.clientId, projectId: p.projectId, accumulatedSeconds: p.seconds,
                itemCount: p.sessionIds.count, itemsJson: sourceRefs(p.sessionIds), status: "rolled_up",
                createdAt: now, updatedAt: now))
            let suggestion = Suggestion(
                day: day, kind: "pool", clientId: p.clientId, projectId: p.projectId,
                minutes: minutes, rawSeconds: p.seconds, note: poolNote(p),
                confidence: max(0.5, p.confidence), producedByRung: p.rung,
                rationale: "pooled \(p.sessionIds.count) micro-work item(s)", isRoundedUp: roundedUp,
                sourceRefsJson: "{\"pool_id\":\(poolId)}", createdAt: now, updatedAt: now)
            try db.insertSuggestion(suggestion)
            summary.pools += 1
        }

        return summary
    }

    private func note(for g: Group) -> String {
        let distinct = Array(Set(g.titles)).prefix(3)
        return distinct.isEmpty ? "Worked on this client's project." : distinct.joined(separator: "; ")
    }
    private func poolNote(_ g: Group) -> String {
        let distinct = Array(Set(g.titles)).prefix(4)
        return distinct.isEmpty ? "Assorted small tasks." : "Assorted: " + distinct.joined(separator: "; ")
    }
    private func proposedTitle(_ g: Group) -> String {
        g.titles.first ?? "New task"
    }
    private func sourceRefs(_ ids: [Int64]) -> String {
        let list = ids.map(String.init).joined(separator: ",")
        return "{\"sessions\":[\(list)]}"
    }
}
