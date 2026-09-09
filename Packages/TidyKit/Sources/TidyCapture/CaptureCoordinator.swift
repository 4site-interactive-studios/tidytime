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
/// **Away.** The coordinator holds one `away` state, fed by three signals, and while it is set
/// nothing is recorded: the idle reader crossing `idleThresholdSeconds` (backdated to when input
/// stopped), the lock screen or screen saver being frontmost (`AwayApps`), and the sleep / lock
/// notifications relayed by `PowerObserver` through `awayBegan` / `awayEnded`. Entering it closes
/// the open sample *at the boundary*; leaving it writes one `away_gaps` row and resumes. Overlaps
/// collapse: the earliest boundary wins and a specific cause (lock, sleep) replaces `idle`.
///
/// Until 2026-09-09 none of this was wired. `PowerObserver`, `IdleReader` and `AwayGapDetector`
/// existed and were tested and had no caller, so the lock screen was recorded as an application —
/// 54% of all screen time — and `away_gaps` had 0 rows after 44 days.
///
/// Pure logic + injected protocols → fully testable by driving `poll()`/`captureContent()` manually.
/// The live Timer/notification wiring lives in `LiveCapture.swift` (`LiveCaptureController`).
public final class CaptureCoordinator: @unchecked Sendable {
    private let reader: FrontmostReading
    private let browser: BrowserAdapter?
    private let recorder: SampleRecorder
    private let policy: ContextSignature.Policy
    private let exclusions: CaptureExclusions
    private let scrubber: URLScrubber
    private let idle: IdleReading?
    private let idleThresholdSeconds: Int
    private let clock: TidyClock

    private let lock = NSLock()
    private var lastSignature: String?
    private var lastContentURL: String?
    private var currentSampleId: Int64?
    private var currentContext: FrontmostContext?
    private var away: AwayState?
    /// When the last gap ended. An idle boundary backdated by the idle counter can never land
    /// before it, or a wake with no input yet would open a second gap inside the one just written.
    private var lastAwayEnd: Int64 = 0

    private struct AwayState {
        var start: Int64
        var cause: String
        /// Who opened it: `poll` (idle counter or the lock screen in front) or a notification.
        var fromNotification: Bool
    }

    /// A lock/sleep gap opened by a notification is normally closed by its matching notification.
    /// `poll` may close it on seeing a real application in front only after this long, because
    /// `willSleep` fires seconds *before* the machine sleeps, with the real app still frontmost —
    /// and macOS's lock/unlock notifications are undocumented, so "never" is not an option either.
    static let notificationGraceSeconds: Int64 = 30

    public init(reader: FrontmostReading, browser: BrowserAdapter?, recorder: SampleRecorder,
                policy: ContextSignature.Policy = .default,
                exclusions: CaptureExclusions = CaptureExclusions(),
                scrubber: URLScrubber = URLScrubber(),
                idle: IdleReading? = nil, idleThresholdSeconds: Int = 600,
                clock: TidyClock = SystemClock()) {
        self.reader = reader
        self.browser = browser
        self.recorder = recorder
        self.policy = policy
        self.exclusions = exclusions
        self.scrubber = scrubber
        self.idle = idle
        self.idleThresholdSeconds = idleThresholdSeconds
        self.clock = clock
    }

    /// Detection tick. Records a new sample iff the observed context changed. Returns true if it did.
    ///
    /// Order matters. The lock screen is checked before idle so that typing the password (input at
    /// the lock screen) does not end an idle gap and immediately open a lock gap; idle is checked
    /// before the "real app in front ends a lock gap" rule so a wake with no input yet stays away.
    @discardableResult
    public func poll() throws -> Bool {
        let now = Int64(clock.now.timeIntervalSince1970)
        guard let observed = reader.current() else { return false }

        // The lock screen is not an application the user is using.
        if AwayApps.isAway(observed.appBundleId) {
            if currentAway() == nil { try beginAway(cause: "lock", at: now, fromNotification: false) }
            return false
        }

        if let idle, idleThresholdSeconds > 0 {
            let idleFor = Int64(idle.idleSeconds())
            if idleFor >= Int64(idleThresholdSeconds) {
                // The block ended when input stopped, not when we noticed — but never before the
                // gap that was just closed.
                if currentAway() == nil { try beginAway(cause: "idle", at: now - idleFor, fromNotification: false) }
                return false
            }
            if let a = currentAway(), a.cause == "idle" { try endAway(at: now) }
        }

        // A real app in front while a lock/sleep gap is open. If `poll` opened it (lock screen was
        // in front), the user is back. If a notification opened it, wait out the grace window —
        // the end notification is the honest boundary, and it may simply not have fired yet.
        if let a = currentAway(), a.cause != "idle",
           !a.fromNotification || now - a.start >= Self.notificationGraceSeconds {
            try endAway(at: now)
        }
        // Still away (inside the grace window): nothing is recorded until the gap ends.
        if currentAway() != nil { return false }

        var ctx = observed
        if exclusions.excludes(appBundleId: ctx.appBundleId) { return try dropCurrent() }
        // Enrich a browser context with the active tab's URL/title (lightweight — no page text).
        if ctx.isBrowser, let browser, let tab = browser.activeTab() {
            // Excluded BEFORE the URL and title are copied onto the context. Recording the row and
            // filtering later would already have put the thing on disk, which is the whole point.
            if tab.isPrivate || exclusions.excludes(url: tab.url) { return try dropCurrent() }
            // Credential-bearing query strings and fragments never reach the context, so neither
            // the sample nor a later page snapshot can carry them (G10). A loopback URL with a
            // query is an OAuth redirect — TidyTime's own included — and is dropped outright.
            switch scrubber.scrub(tab.url) {
            case .drop: return try dropCurrent()
            case .store(let safe): ctx.url = safe
            }
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

    /// Forget the current context without recording anything, and close the open sample now: an
    /// excluded page is a hole in the timeline, not time that belongs to whatever came before it.
    /// (Until the 2026-09-09 review the sample stayed open and was closed by the next record — so
    /// two hours on an excluded site were attributed to the previous app.)
    ///
    /// Clearing `currentSampleId` matters as much as skipping the insert: a later content tick reads
    /// it, and leaving the previous sample's id in place would file the excluded page's text under
    /// the last thing that *was* recorded. Clearing `lastSignature` means stepping back out of the
    /// excluded window records a fresh sample rather than being swallowed as "unchanged".
    private func dropCurrent() throws -> Bool {
        try recorder.closeOpenSample(at: Int64(clock.now.timeIntervalSince1970))
        forgetCurrent()
        return false
    }

    private func forgetCurrent() {
        lock.lock()
        currentContext = nil
        currentSampleId = nil
        lastSignature = nil
        lastContentURL = nil
        lock.unlock()
    }

    // MARK: Away

    public var isAway: Bool { currentAway() != nil }

    private func currentAway() -> AwayState? {
        lock.lock(); defer { lock.unlock() }
        return away
    }

    /// Enter the away state at `start` (clamped to the end of the previous gap): close the open
    /// sample there, forget the context, remember the boundary. Recording resumes on `endAway`.
    private func beginAway(cause: String, at start: Int64, fromNotification: Bool) throws {
        lock.lock(); let floor = lastAwayEnd; lock.unlock()
        let clamped = max(start, floor)
        try recorder.closeOpenSample(at: clamped)
        forgetCurrent()
        lock.lock(); away = AwayState(start: clamped, cause: cause, fromNotification: fromNotification); lock.unlock()
    }

    /// Leave the away state: one `away_gaps` row for the closed interval, written BEFORE the state
    /// is cleared, so a failed insert leaves the gap open to be retried rather than lost. The next
    /// `poll` records a fresh sample because `forgetCurrent` cleared the signature.
    private func endAway(at end: Int64) throws {
        guard let a = currentAway() else { return }
        if end > a.start {
            try recorder.recordAwayGap(AwayGapDraft(
                start: a.start, end: end, durationSeconds: Int(end - a.start), cause: a.cause))
        }
        lock.lock(); away = nil; lastAwayEnd = max(lastAwayEnd, end); lock.unlock()
    }

    /// A sleep or lock notification. If already idle, keep the earlier boundary and take the more
    /// specific cause; if already in a lock/sleep gap, the first one stands (a sleep that follows a
    /// lock is still the same absence).
    public func awayBegan(cause: String, at date: Date) throws {
        let at = Int64(date.timeIntervalSince1970)
        guard let a = currentAway() else { return try beginAway(cause: cause, at: at, fromNotification: true) }
        if a.cause == "idle" { lock.lock(); away?.cause = cause; away?.fromNotification = true; lock.unlock() }
    }

    /// A wake or unlock notification. Ends the gap only when its cause matches: a wake while the
    /// screen is still locked is not the user coming back, and `poll` will see the lock screen.
    public func awayEnded(cause: String, at date: Date) throws {
        guard let a = currentAway(), a.cause == cause else { return }
        try endAway(at: Int64(date.timeIntervalSince1970))
    }

    /// Capture is stopping (pause, quit). Close the open sample now and bank any open gap, so
    /// nothing is left dangling for the next launch to stretch.
    public func suspend() throws {
        let now = Int64(clock.now.timeIntervalSince1970)
        if currentAway() != nil { try endAway(at: now) }
        try recorder.closeOpenSample(at: now)
        forgetCurrent()
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
