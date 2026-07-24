import Foundation
import TidyCore
import TidyStore

/// Writes capture rows: closes the previously open sample and inserts a new one on each context
/// change/heartbeat; stores page text only when it changed (content-hash dedup). Fully testable
/// with an in-memory `AppDatabase` + `FixedClock`.
public struct SampleRecorder: Sendable {
    private let db: AppDatabase
    private let clock: TidyClock
    private let policy: PageTextPolicy
    private let browserName: String

    public init(db: AppDatabase, clock: TidyClock = SystemClock(),
                policy: PageTextPolicy = PageTextPolicy(), browserName: String = "chrome") {
        self.db = db; self.clock = clock; self.policy = policy; self.browserName = browserName
    }

    /// Record a new activity sample, closing whatever was open. Returns the new sample id.
    @discardableResult
    public func record(_ context: FrontmostContext, source: String = "switch") throws -> Int64 {
        let now = Int64(clock.now.timeIntervalSince1970)
        try db.closeOpenSample(before: now)
        let sample = ActivitySample(
            startedAt: now, appBundleId: context.appBundleId, appName: context.appName,
            windowTitle: context.windowTitle, isBrowser: context.isBrowser,
            browser: context.isBrowser ? browserName : nil, url: context.url,
            source: source, createdAt: now)
        return try db.insertSample(sample)
    }

    /// Store page text for a sample unless an identical snapshot already exists for this URL.
    /// Returns true if stored, false if skipped as a duplicate.
    @discardableResult
    public func recordPageText(sampleId: Int64, url: String, title: String?, rawText: String) throws -> Bool {
        let prepared = policy.prepare(rawText)
        let previous = try db.latestSnapshotHash(url: url)
        guard policy.shouldStore(newHash: prepared.hash, previousHash: previous) else { return false }
        let now = Int64(clock.now.timeIntervalSince1970)
        try db.insertPageSnapshot(PageSnapshot(
            sampleId: sampleId, capturedAt: now, url: url, title: title,
            contentHash: prepared.hash, text: prepared.text, textBytes: prepared.bytes))
        return true
    }

    public func recordAwayGap(_ draft: AwayGapDraft) throws {
        let now = Int64(clock.now.timeIntervalSince1970)
        try db.insertAwayGap(AwayGap(
            startedAt: draft.start, endedAt: draft.end, durationSeconds: draft.durationSeconds,
            cause: draft.cause, createdAt: now))
    }
}
