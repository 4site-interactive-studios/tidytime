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
    /// Enough config to build a task deep link. Optional so tests need not supply one; when absent
    /// the column stays NULL and the UI hides the button, which is the correct degradation.
    private let organization: Config.Organization?
    private let deepLinkPattern: String?

    public init(db: AppDatabase, clock: TidyClock = SystemClock(), rounding: RoundingPolicy = RoundingPolicy(),
                standaloneThresholdMinutes: Int = 15, poolThresholdMinutes: Int = 5, selfPersonId: String? = nil,
                organization: Config.Organization? = nil, deepLinkPattern: String? = nil) {
        self.db = db; self.clock = clock; self.rounding = rounding
        self.standaloneThresholdMinutes = standaloneThresholdMinutes
        self.poolThresholdMinutes = poolThresholdMinutes; self.selfPersonId = selfPersonId
        self.organization = organization; self.deepLinkPattern = deepLinkPattern
    }

    /// The task's URL in the Productive web app, or nil when the config cannot fill the pattern.
    /// Stored on the row so the view needs neither `Config` nor a dependency on `TidyIngest`.
    private func deepLink(taskId: String?) -> String? {
        guard let taskId, let organization, let pattern = deepLinkPattern else { return nil }
        return ProductiveDeepLink.url(taskId: taskId,
                                      organizationId: organization.productiveOrganizationId,
                                      organizationSlug: organization.productiveOrgSlug,
                                      pattern: pattern)
    }

    public struct Summary: Sendable, Equatable {
        public var standalone: Int
        public var pools: Int
        /// Pools too small to be worth a full billing increment. Reported, never silent.
        public var droppedBelowPoolThreshold: Int = 0
        public var droppedPoolSeconds: Int = 0
        public var newTaskProposals: Int
        public var skippedAlreadyLogged: Int
        /// Groups left alone because the user already logged/tossed them on this day.
        public var skippedAlreadyDecided: Int = 0
        public init(standalone: Int = 0, pools: Int = 0, newTaskProposals: Int = 0,
                    skippedAlreadyLogged: Int = 0, skippedAlreadyDecided: Int = 0) {
            self.standalone = standalone; self.pools = pools
            self.newTaskProposals = newTaskProposals
            self.skippedAlreadyLogged = skippedAlreadyLogged
            self.skippedAlreadyDecided = skippedAlreadyDecided
        }
    }

    private struct Group {
        var clientId: String
        var projectId: String?
        var taskId: String?
        var seconds: Int = 0
        var sessionIds: [Int64] = []
        var titles: [String] = []
        var rung: Int = 5
        var isMeeting = false

        /// Duration-weighted, not `max`. Taking the best session's confidence let a single
        /// exact-URL match drag an otherwise-speculative group up to 0.97, so a card claiming
        /// near-certainty could be 90% guesswork by time. The weighted mean says what the card
        /// as a whole is worth, which is what the number is for.
        var confidenceSeconds: Double = 0
        var confidence: Double { seconds > 0 ? confidenceSeconds / Double(seconds) : 0 }

        mutating func absorb(seconds: Int, confidence: Double) {
            self.seconds += seconds
            self.confidenceSeconds += confidence * Double(seconds)
        }
    }

    @discardableResult
    public func generate(day: String, from: Int64, to: Int64) throws -> Summary {
        // Preserve what the user already decided. A full clear would resurrect every tossed card on
        // the next 300s pass and orphan the decisions audit trail.
        let decided = try db.clearPendingSuggestions(day: day)
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
            g.absorb(seconds: s.durationSeconds, confidence: s.confidence ?? 0)
            if let id = s.id { g.sessionIds.append(id) }
            if let t = s.title, !t.isEmpty { g.titles.append(t) }
            g.rung = min(g.rung, s.producedByRung ?? 5)
            if s.kind == "meeting" { g.isMeeting = true }
            groups[key] = g
        }

        var summary = Summary(standalone: 0, pools: 0, newTaskProposals: 0, skippedAlreadyLogged: 0)
        var pools: [String: Group] = [:]   // keyed by project/client for sub-threshold work

        for (_, g) in groups {
            // Already settled by the user this day — do not re-propose it. Keyed on the work, not
            // the kind: at this point the engine has not yet decided whether this group becomes a
            // session, a new-task proposal, or part of a pool, and guessing produced a key that
            // could never match a tossed pool.
            let settledKey = Suggestion.workKey(clientId: g.clientId, projectId: g.projectId, taskId: g.taskId)
            if decided.contains(settledKey) { summary.skippedAlreadyDecided += 1; continue }
            let rawMinutes = g.seconds / 60
            if rawMinutes >= standaloneThresholdMinutes {
                // Gap analysis: for a known task, subtract already-logged time from the RAW seconds
                // BEFORE rounding, so the remainder is still a clean 15-min increment (not e.g. 35m).
                var effectiveSeconds = g.seconds
                var rationaleExtra = ""
                if let taskId = g.taskId, let logged = loggedByTask[taskId], logged > 0 {
                    effectiveSeconds = g.seconds - logged * 60
                    rationaleExtra = " (you logged \(logged)m; suggesting the remainder)"
                    // A remainder below the threshold means the task is substantially logged already —
                    // skip rather than round a tiny remainder up to a full increment (over-counting).
                    if effectiveSeconds < standaloneThresholdMinutes * 60 {
                        summary.skippedAlreadyLogged += 1; continue
                    }
                }
                let (suggestMinutes, roundedUp) = rounding.rounded(seconds: effectiveSeconds)
                let kind: String
                if g.taskId != nil { kind = g.isMeeting ? "meeting_segment" : "session" }
                else { kind = "new_task"; summary.newTaskProposals += 1 }

                let suggestion = Suggestion(
                    day: day, kind: kind, clientId: g.clientId, projectId: g.projectId, taskId: g.taskId,
                    proposedTaskTitle: kind == "new_task" ? proposedTitle(g) : nil,
                    minutes: suggestMinutes, rawSeconds: g.seconds, note: note(for: g),
                    confidence: g.confidence, producedByRung: g.rung,
                    rationale: "grouped \(g.sessionIds.count) session(s)" + rationaleExtra,
                    isRoundedUp: roundedUp, deepLink: deepLink(taskId: g.taskId),
                    sourceRefsJson: sourceRefs(g.sessionIds),
                    createdAt: now, updatedAt: now)
                try db.insertSuggestion(suggestion)
                summary.standalone += 1
            } else {
                let poolKey = g.projectId.map { "p:" + $0 } ?? "c:" + g.clientId
                var p = pools[poolKey] ?? Group(clientId: g.clientId, projectId: g.projectId)
                p.absorb(seconds: g.seconds, confidence: g.confidence)
                p.sessionIds.append(contentsOf: g.sessionIds)
                p.titles.append(contentsOf: g.titles)
                p.rung = min(p.rung, g.rung)
                pools[poolKey] = p
            }
        }

        // Each pool that rolls up costs a full billing increment, so the count of pools — not their
        // size — sets the day's inflation. Live, ten pools holding 80 real minutes were suggesting
        // 150: three of them held 1.2, 2.5 and 3.2 minutes and each bought a 15-minute card.
        //
        // A 72-second fragment is not billable work, it is a lexical rung's noise wearing a client's
        // name, and rounding it up 12x makes a data-quality problem look like a rounding rule. So a
        // pool must hold at least `poolThresholdMinutes` before it is worth a card. That parameter
        // existed and was explicitly discarded (`_ = poolThresholdMinutes`) — this is the job it was
        // named for.
        //
        // What survives is still inflated, and legitimately: seven clients touched for a few minutes
        // each, billed at a 15-minute minimum, IS 105 minutes. That is what increment billing means,
        // not a defect. `Summary.droppedBelowPoolThreshold` reports what was set aside so the choice
        // is visible rather than silent.
        for (_, p) in pools where p.seconds > 0 {
            guard p.seconds >= poolThresholdMinutes * 60 else {
                summary.droppedBelowPoolThreshold += 1
                summary.droppedPoolSeconds += p.seconds
                continue
            }
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
