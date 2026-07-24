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

    private let lock = NSLock()
    private var lastSignature: String?
    private var currentSampleId: Int64?
    private var currentContext: FrontmostContext?

    public init(reader: FrontmostReading, browser: BrowserAdapter?, recorder: SampleRecorder) {
        self.reader = reader
        self.browser = browser
        self.recorder = recorder
    }

    /// Detection tick. Records a new sample iff the observed context changed. Returns true if it did.
    @discardableResult
    public func poll() throws -> Bool {
        guard let observed = reader.current() else { return false }
        var ctx = observed
        // Enrich a browser context with the active tab's URL/title (lightweight — no page text).
        if ctx.isBrowser, let browser, let tab = browser.activeTab() {
            ctx.url = tab.url
            if let title = tab.title, !title.isEmpty { ctx.windowTitle = title }
        }
        let signature = Self.signature(ctx)

        lock.lock()
        let unchanged = signature == lastSignature
        lock.unlock()
        if unchanged { return false }

        let id = try recorder.record(ctx, source: "switch")
        lock.lock()
        lastSignature = signature
        currentSampleId = id
        currentContext = ctx
        lock.unlock()

        // Grab page content immediately on landing in a new browser context.
        try? captureContent()
        return true
    }

    /// Content tick. Captures + stores page text for the current browser sample (deduped). No-op for
    /// non-browser contexts or when scripting is unavailable.
    public func captureContent() throws {
        lock.lock()
        let ctx = currentContext
        let id = currentSampleId
        lock.unlock()
        guard let ctx, ctx.isBrowser, let id, let browser, let url = ctx.url,
              let text = browser.visiblePageText(), !text.isEmpty else { return }
        _ = try recorder.recordPageText(sampleId: id, url: url, title: ctx.windowTitle, rawText: text)
    }

    /// The change key: app + window title + URL. A within-app title/tab change flips it, which is
    /// what gives sub-app (per-chat / per-tab) granularity.
    static func signature(_ c: FrontmostContext) -> String {
        "\(c.appBundleId)\u{1}\(c.windowTitle ?? "")\u{1}\(c.url ?? "")"
    }
}
