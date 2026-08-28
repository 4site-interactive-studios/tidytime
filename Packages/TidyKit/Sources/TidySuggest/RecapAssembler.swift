import Foundation
import TidyCore
import TidyStore

/// Assembles the end-of-day recap read model (the SwiftUI recap window renders this) and computes
/// the daily rollup metrics. Pure read side — no capture, no network.
public struct RecapDay: Sendable, Equatable {
    public let day: String
    public let timeline: [Session]                 // sessions ordered by start (colored by client in UI)
    public let suggestions: [Suggestion]           // sorted by confidence desc
    public let questions: [ResolutionQuestion]     // ask-once unresolved signals
    public let observedSeconds: Int
    public let attributedSeconds: Int
    public let loggedMinutes: Int
    /// How fragmented the day was — switches, dwell, thrash (from raw samples, not sessions).
    public let contextSwitches: ContextSwitchMetrics
    /// Human names for the ids a suggestion carries, keyed by id.
    ///
    /// The card previously rendered `suggestion.taskId ?? projectId ?? clientId` — so the best
    /// cards, the ones attributed all the way down to a task, were headed by a bare number like
    /// `18609405`. Resolved here rather than in the view so `RecapView` stays a pure function of
    /// its input and needs no database.
    public var names: [String: String] = [:]
    /// % of observed time that got attributed to a client (capture health).
    public var attributionRate: Double {
        observedSeconds > 0 ? Double(attributedSeconds) / Double(observedSeconds) : 0
    }
}

public struct RecapAssembler: Sendable {
    /// Resolve the ids a card would otherwise show raw. Looked up per suggestion rather than by
    /// loading all 11,631 tasks — a day has a handful of cards.
    static func names(for suggestions: [Suggestion], db: AppDatabase) -> [String: String] {
        var out: [String: String] = [:]
        for s in suggestions {
            if let id = s.taskId, out[id] == nil, let t = ((try? db.task(id: id)) ?? nil) { out[id] = t.title }
            if let id = s.projectId, out[id] == nil, let p = ((try? db.project(id: id)) ?? nil) { out[id] = p.name }
            if let id = s.clientId, out[id] == nil, let c = ((try? db.company(id: id)) ?? nil) { out[id] = c.name }
        }
        return out
    }

    private let db: AppDatabase
    private let clock: TidyClock
    private let selfPersonId: String?
    private let contextPolicy: ContextSignature.Policy

    public init(db: AppDatabase, clock: TidyClock = SystemClock(), selfPersonId: String? = nil,
                contextPolicy: ContextSignature.Policy = .default) {
        self.db = db; self.clock = clock; self.selfPersonId = selfPersonId
        self.contextPolicy = contextPolicy
    }

    /// Convenience: derive the context policy straight from config.
    public init(db: AppDatabase, config: Config, clock: TidyClock = SystemClock(), selfPersonId: String? = nil) {
        self.init(db: db, clock: clock, selfPersonId: selfPersonId,
                  contextPolicy: ContextSignature.Policy(config.capture))
    }

    public func assemble(day: String, from: Int64, to: Int64) throws -> RecapDay {
        let sessions = try db.sessions(from: from, to: to)
        let observed = sessions.reduce(0) { $0 + $1.durationSeconds }
        let attributed = sessions.filter { $0.clientId != nil }.reduce(0) { $0 + $1.durationSeconds }
        var logged = 0
        if let personId = selfPersonId {
            logged = ((try? db.timeEntries(personId: personId, date: day)) ?? []).reduce(0) { $0 + $1.timeMinutes }
        }
        // Context switching is computed from RAW samples so sub-minute thrash still counts. The
        // analyzer drops unattended spans (>= idleThreshold) so an overnight gap can't register as
        // focus, and clamps a trailing open sample to `now` (round-2 finding R1-2).
        let now = Int64(clock.now.timeIntervalSince1970)
        let awayGaps = (try? db.awayGaps(from: from, to: to)) ?? []
        let switches = ContextSwitchAnalyzer(policy: contextPolicy)
            .analyze(try db.samples(from: from, to: to), now: min(now, to), awayGaps: awayGaps)
        // Only pending cards. The table keeps logged/tossed rows as the decision record, but a card
        // the user already dismissed must not keep rendering with live buttons — `MenuBarPopover`
        // already filters this way and the recap did not, so its count and the popover's disagreed.
        let pending = try db.suggestions(day: day).filter { $0.status == "pending" }

        var recap = RecapDay(
            day: day, timeline: sessions, suggestions: pending,
            questions: try db.openQuestions(), observedSeconds: observed,
            attributedSeconds: attributed, loggedMinutes: logged, contextSwitches: switches)
        recap.names = Self.names(for: pending, db: db)
        return recap
    }

    /// Persist the day's rollup metrics (dashboard input).
    @discardableResult
    public func writeRollup(day: String, from: Int64, to: Int64) throws -> DailyRollup {
        let recap = try assemble(day: day, from: from, to: to)
        let now = Int64(clock.now.timeIntervalSince1970)
        let rollup = DailyRollup(
            day: day, observedSeconds: recap.observedSeconds, attributedSeconds: recap.attributedSeconds,
            loggedMinutes: recap.loggedMinutes, captureHealth: recap.attributionRate,
            contextSwitches: recap.contextSwitches.switchCount,
            briefSwitches: recap.contextSwitches.briefSwitches,
            longestFocusSeconds: recap.contextSwitches.longestFocusSeconds,
            createdAt: now, updatedAt: now)
        try db.upsertRollup(rollup)
        return rollup
    }
}
