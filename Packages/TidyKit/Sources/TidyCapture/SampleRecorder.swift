import Foundation
import TidyCore
import TidyStore

/// Writes capture rows: closes the previously open sample and inserts a new one on each context
/// change/heartbeat; stores page text only when it changed (content-hash dedup). Fully testable
/// with an in-memory `AppDatabase` + `FixedClock`.
///
/// This is the last stop before the insert, so it is also the last line of G10: URLs are scrubbed
/// and titles / page text are pattern-redacted *here*, whatever the caller did. `CaptureCoordinator`
/// scrubs earlier so that a credential never even reaches the in-memory context; this repeats the
/// scrub so a second caller — a test, a future heartbeat path — cannot bypass it.
public struct SampleRecorder: Sendable {
    private let db: AppDatabase
    private let clock: TidyClock
    private let policy: PageTextPolicy
    private let browserName: String
    private let scrubber: URLScrubber

    public init(db: AppDatabase, clock: TidyClock = SystemClock(),
                policy: PageTextPolicy = PageTextPolicy(), browserName: String = "chrome",
                scrubber: URLScrubber = URLScrubber()) {
        self.db = db; self.clock = clock; self.policy = policy; self.browserName = browserName
        self.scrubber = scrubber
    }

    /// Record a new activity sample, closing whatever was open. Returns the new sample id.
    @discardableResult
    public func record(_ context: FrontmostContext, source: String = "switch") throws -> Int64 {
        let now = Int64(clock.now.timeIntervalSince1970)
        try db.closeOpenSample(before: now)
        let sample = ActivitySample(
            startedAt: now, appBundleId: context.appBundleId, appName: context.appName,
            windowTitle: Redactor.redact(context.windowTitle), isBrowser: context.isBrowser,
            browser: context.isBrowser ? browserName : nil, url: scrubber.stored(context.url),
            source: source, createdAt: now)
        return try db.insertSample(sample)
    }

    /// Store page text for a sample unless an identical snapshot already exists for this URL.
    /// Returns true if stored, false if skipped as a duplicate.
    ///
    /// The dedup hash is computed over the *redacted* text: two pages that differ only in a
    /// credential the store never keeps are the same page as far as the store is concerned.
    @discardableResult
    public func recordPageText(sampleId: Int64, url: String, title: String?, rawText: String) throws -> Bool {
        guard let safeURL = scrubber.stored(url) else { return false }
        let prepared = policy.prepare(Redactor.redact(rawText))
        let previous = try db.latestSnapshotHash(url: safeURL)
        guard policy.shouldStore(newHash: prepared.hash, previousHash: previous) else { return false }
        let now = Int64(clock.now.timeIntervalSince1970)
        try db.insertPageSnapshot(PageSnapshot(
            sampleId: sampleId, capturedAt: now, url: safeURL, title: Redactor.redact(title),
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
