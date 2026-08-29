import Foundation
import TidyCore
import TidyStore

/// Tiered capture driver. Two cadences, both change-gated so a fast poll doesn't bloat the DB:
///
///  - **detection tick** (`poll`, fast — e.g. every 1s + on every app-activation event): reads the
///    frontmost app + window title, and for a browser the active tab's URL/title (cheap AppleScript,
///    NOT page text). Records a NEW `activity_samples` row **only when the context signature changes**
///    (app / window title / URL) — so sitting on one thing for minutes is a single open sample, but
///    switching chats/tabs *within* an app creates a distinct sample the instant the title/URL differs.
///  - **content tick** (`captureContent`, slow — e.g. every 20s, and once right after a browser change):
///    grabs `document.body.innerText` for the current browser sample, deduped by content hash.
///
/// Pure logic + injected protocols → fully testable by driving `poll()`/`captureContent()` manually.
/// The live Timer/notification wiring lives in `LiveCapture.swift` (`LiveCaptureController`).
public final class CaptureCoordinator: @unchecked Sendable {
    private let reader: FrontmostReading
    private let browser: BrowserAdapter?
    private let recorder: SampleRecorder
    private let policy: ContextSignature.Policy
    private let exclusions: CaptureExclusions

    private let lock = NSLock()
    private var lastSignature: String?
    private var lastContentURL: String?
    private var currentSampleId: Int64?
    private var currentContext: FrontmostContext?

    public init(reader: FrontmostReading, browser: BrowserAdapter?, recorder: SampleRecorder,
                policy: ContextSignature.Policy = .default,
                exclusions: CaptureExclusions = CaptureExclusions()) {
        self.reader = reader
        self.browser = browser
        self.recorder = recorder
        self.policy = policy
        self.exclusions = exclusions
    }

    /// Detection tick. Records a new sample iff the observed context changed. Returns true if it did.
    @discardableResult
    public func poll() throws -> Bool {
        guard let observed = reader.current() else { return false }
        var ctx = observed
        if exclusions.excludes(appBundleId: ctx.appBundleId) { return dropCurrent() }
        // Enrich a browser context with the active tab's URL/title (lightweight — no page text).
        if ctx.isBrowser, let browser, let tab = browser.activeTab() {
            // Excluded BEFORE the URL and title are copied onto the context. Recording the row and
            // filtering later would already have put the thing on disk, which is the whole point.
            if tab.isPrivate || exclusions.excludes(url: tab.url) { return dropCurrent() }
            ctx.url = tab.url
            if let title = tab.title, !title.isEmpty { ctx.windowTitle = title }
        }
        let signature = Self.signature(ctx, policy: policy)

        lock.lock()
        let unchanged = signature == lastSignature
        // Refresh-without-recording: the normalized context is the same (e.g. only `?msg=` churned),
        // but keep the live raw context so a later page-snapshot files under the URL actually on
        // screen. No new row, and deliberately no content capture.
        if unchanged { currentContext = ctx }
        lock.unlock()
        if unchanged { return false }

        let id = try recorder.record(ctx, source: "switch")
        lock.lock()
        lastSignature = signature
        currentSampleId = id
        currentContext = ctx
        lock.unlock()

        // Grab page content on landing in a new browser context — but only when the *page* changed,
        // not merely the title (R3-6: otherwise a title-churning tab re-fires an expensive
        // `innerText` AppleScript on every detection tick).
        if ctx.isBrowser {
            let normalized = ContextSignature.normalizedURL(ctx.url, policy: policy)
            lock.lock()
            let pageChanged = normalized != lastContentURL
            lock.unlock()
            if pageChanged { try? captureContent() }
        }
        return true
    }

    /// Forget the current context without recording anything.
    ///
    /// Clearing `currentSampleId` matters as much as skipping the insert: a later content tick reads
    /// it, and leaving the previous sample's id in place would file the excluded page's text under
    /// the last thing that *was* recorded. Clearing `lastSignature` means stepping back out of the
    /// excluded window records a fresh sample rather than being swallowed as "unchanged".
    private func dropCurrent() -> Bool {
        lock.lock()
        currentContext = nil
        currentSampleId = nil
        lastSignature = nil
        lastContentURL = nil
        lock.unlock()
        return false
    }

    /// Content tick. Captures + stores page text for the current browser sample (deduped). No-op for
    /// non-browser contexts or when scripting is unavailable.
    public func captureContent() throws {
        lock.lock()
        let ctx = currentContext
        let id = currentSampleId
        lock.unlock()
        guard let ctx, ctx.isBrowser, let id, let browser, let url = ctx.url,
              !exclusions.excludes(url: url), !exclusions.excludes(appBundleId: ctx.appBundleId),
              let text = browser.visiblePageText(), !text.isEmpty else { return }
        _ = try recorder.recordPageText(sampleId: id, url: url, title: ctx.windowTitle, rawText: text)
        lock.lock()
        lastContentURL = ContextSignature.normalizedURL(url, policy: policy)
        lock.unlock()
    }

    /// The change key. Delegates to `TidyCore.ContextSignature` so capture gating, the
    /// context-switch metric, and sessionization share ONE definition (round-2 finding R1-1).
    /// A within-app title/tab change flips it (sub-app granularity); per-message query/fragment
    /// churn and unread-badge ticks do not.
    static func signature(_ c: FrontmostContext, policy: ContextSignature.Policy = .default) -> String {
        ContextSignature.key(appBundleId: c.appBundleId, windowTitle: c.windowTitle, url: c.url, policy: policy)
    }
}
