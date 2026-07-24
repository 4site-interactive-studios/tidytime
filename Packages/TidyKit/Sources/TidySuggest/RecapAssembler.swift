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
    /// % of observed time that got attributed to a client (capture health).
    public var attributionRate: Double {
        observedSeconds > 0 ? Double(attributedSeconds) / Double(observedSeconds) : 0
    }
}

public struct RecapAssembler: Sendable {
    private let db: AppDatabase
    private let clock: TidyClock
    private let selfPersonId: String?

    public init(db: AppDatabase, clock: TidyClock = SystemClock(), selfPersonId: String? = nil) {
        self.db = db; self.clock = clock; self.selfPersonId = selfPersonId
    }

    public func assemble(day: String, from: Int64, to: Int64) throws -> RecapDay {
        let sessions = try db.sessions(from: from, to: to)
        let observed = sessions.reduce(0) { $0 + $1.durationSeconds }
        let attributed = sessions.filter { $0.clientId != nil }.reduce(0) { $0 + $1.durationSeconds }
        var logged = 0
        if let personId = selfPersonId {
            logged = ((try? db.timeEntries(personId: personId, date: day)) ?? []).reduce(0) { $0 + $1.timeMinutes }
        }
        // Context switching is computed from RAW samples so sub-minute thrash still counts.
        let now = Int64(clock.now.timeIntervalSince1970)
        let switches = ContextSwitchAnalyzer().analyze(try db.samples(from: from, to: to), now: now)
        return RecapDay(
            day: day, timeline: sessions, suggestions: try db.suggestions(day: day),
            questions: try db.openQuestions(), observedSeconds: observed,
            attributedSeconds: attributed, loggedMinutes: logged, contextSwitches: switches)
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
