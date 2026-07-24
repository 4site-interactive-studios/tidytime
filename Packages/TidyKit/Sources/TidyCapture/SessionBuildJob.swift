import Foundation
import TidyCore
import TidyStore

/// Turns stored `ActivitySample` rows into `Session` rows via the `Sessionizer`. Splitting the
/// slice-building out makes it testable without a DB.
public struct SessionBuildJob: Sendable {
    private let sessionizer: Sessionizer
    private let clock: TidyClock

    public init(sessionizer: Sessionizer, clock: TidyClock = SystemClock()) {
        self.sessionizer = sessionizer
        self.clock = clock
    }

    /// Build slices: each sample spans [started_at, ended_at ?? nextStart ?? now]; context key
    /// derived from browser host or app bundle.
    public func slices(from samples: [ActivitySample], now: Int64) -> [SampleSlice] {
        let sorted = samples.sorted { $0.startedAt < $1.startedAt }
        var out: [SampleSlice] = []
        for (idx, s) in sorted.enumerated() {
            guard let id = s.id else { continue }
            let fallbackEnd = idx + 1 < sorted.count ? sorted[idx + 1].startedAt : now
            let end = s.endedAt ?? fallbackEnd
            let context = ContextKey.derive(isBrowser: s.isBrowser, url: s.url, appBundleId: s.appBundleId)
            let grouping = ContextKey.grouping(isBrowser: s.isBrowser, url: s.url,
                                               appBundleId: s.appBundleId, windowTitle: s.windowTitle)
            out.append(SampleSlice(
                id: id, start: s.startedAt, end: max(s.startedAt, end),
                contextKey: context, groupingKey: grouping, appBundleId: s.appBundleId, title: s.windowTitle))
        }
        return out
    }

    public func drafts(from samples: [ActivitySample], now: Int64) -> [SessionDraft] {
        sessionizer.sessions(from: slices(from: samples, now: now))
    }

    /// Read samples in [start, end), build sessions, and persist them. Returns count written.
    @discardableResult
    public func run(_ db: AppDatabase, from start: Int64, to end: Int64, now: Int64) throws -> Int {
        let samples = try db.samples(from: start, to: end)
        let drafts = drafts(from: samples, now: now)
        let createdAt = Int64(clock.now.timeIntervalSince1970)
        for d in drafts {
            let session = Session(
                kind: "screen", startedAt: d.start, endedAt: d.end, durationSeconds: d.durationSeconds,
                title: d.title, contextKey: d.contextKey, primaryApp: d.primaryApp, createdAt: createdAt)
            try db.insertSession(session)
        }
        return drafts.count
    }
}
