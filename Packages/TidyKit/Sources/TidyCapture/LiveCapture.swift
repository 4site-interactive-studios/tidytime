// Live macOS capture adapters. Compile-checked but NOT unit-tested — they require a running app,
// granted Accessibility/Automation, and a real browser (see DECISIONS.md, Phase 0: headless
// strategy). All logic they feed (Sessionizer, SampleRecorder, PageTextPolicy, AwayGapDetector) is
// tested separately with fakes.
import Foundation
import TidyCore
import TidyStore

public enum KnownApps {
    public static let chrome = "com.google.Chrome"
    public static let safari = "com.apple.Safari"
    public static let zoom = "us.zoom.xos"
    public static let meetBundlePrefixes = ["com.google"] // Meet runs in the browser
}

#if canImport(AppKit)
import AppKit
import ApplicationServices
import CoreGraphics

/// Chrome adapter via AppleScript / Apple Events. Requires the one-time toggle
/// View → Developer → "Allow JavaScript from Apple Events" for page text
/// (see docs/reference/chrome-scripting.md). Degrades to URL+title when off.
public struct ChromeAdapter: BrowserAdapter {
    public let browserName = "chrome"
    public let appBundleId = KnownApps.chrome
    public init() {}

    public func activeTab() -> BrowserTab? {
        let script = """
        tell application "Google Chrome"
            if (count of windows) = 0 then return ""
            set theURL to URL of active tab of front window
            set theTitle to title of active tab of front window
            return theURL & "\\n" & theTitle
        end tell
        """
        guard let out = Self.run(script), !out.isEmpty else { return nil }
        let parts = out.components(separatedBy: "\n")
        let url = parts.first ?? ""
        guard !url.isEmpty else { return nil }
        let title = parts.count > 1 ? parts[1] : nil
        return BrowserTab(url: url, title: title)
    }

    public func visiblePageText() -> String? {
        guard javaScriptFromAppleEventsEnabled() else { return nil }
        let script = """
        tell application "Google Chrome"
            if (count of windows) = 0 then return ""
            execute active tab of front window javascript "document.body.innerText"
        end tell
        """
        return Self.run(script)
    }

    public func javaScriptFromAppleEventsEnabled() -> Bool {
        let script = """
        tell application "Google Chrome"
            if (count of windows) = 0 then return "1"
            execute active tab of front window javascript "1"
        end tell
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        return err == nil && result != nil
    }

    private static func run(_ source: String) -> String? {
        var err: NSDictionary?
        guard let apple = NSAppleScript(source: source) else { return nil }
        let descriptor = apple.executeAndReturnError(&err)
        if err != nil { return nil }
        return descriptor.stringValue
    }
}

/// Reads the frontmost app + focused window title via NSWorkspace + Accessibility (NOT
/// CGWindowList — guardrail G3). `@MainActor` because it touches NSWorkspace/AX.
@MainActor
public final class FrontmostReader: FrontmostReading {
    private let browserBundleIds: Set<String>
    public init(browserBundleIds: Set<String> = [KnownApps.chrome]) {
        self.browserBundleIds = browserBundleIds
    }

    public nonisolated func current() -> FrontmostContext? {
        MainActor.assumeIsolated { self.readCurrent() }
    }

    private func readCurrent() -> FrontmostContext? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else { return nil }
        let title = focusedWindowTitle(pid: app.processIdentifier)
        return FrontmostContext(
            appBundleId: bundleId,
            appName: app.localizedName ?? bundleId,
            windowTitle: title,
            isBrowser: browserBundleIds.contains(bundleId))
    }

    private func focusedWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused else { return nil }
        // swiftlint:disable:next force_cast
        let windowElement = window as! AXUIElement
        var titleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleValue) == .success
        else { return nil }
        return titleValue as? String
    }
}

/// Subscribes to app-activation notifications and calls `onChange` with the new frontmost context.
@MainActor
public final class AppWatcher {
    private let reader: FrontmostReader
    private let onChange: (FrontmostContext) -> Void
    private var token: NSObjectProtocol?

    public init(reader: FrontmostReader = FrontmostReader(), onChange: @escaping (FrontmostContext) -> Void) {
        self.reader = reader
        self.onChange = onChange
    }

    public func start() {
        let nc = NSWorkspace.shared.notificationCenter
        token = nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit() }
        }
        emit()
    }

    public func stop() {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }

    private func emit() {
        if let context = reader.current() { onChange(context) }
    }
}

/// Idle seconds via CoreGraphics. Takes the min across concrete input event types (avoids the
/// invalid "any event type" raw value that would trap at runtime).
public struct IdleReader: IdleReading {
    public init() {}
    public func idleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown,
                                    .scrollWheel, .otherMouseDown, .flagsChanged]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }
}

/// Observes sleep/wake and screen lock/unlock, emitting an away gap for each closed interval.
@MainActor
public final class PowerObserver {
    private let onGap: (AwayGapDraft) -> Void
    private let clock: () -> Date
    private var intervalStart: Date?
    private var tokens: [NSObjectProtocol] = []

    public init(clock: @escaping () -> Date = { Date() }, onGap: @escaping (AwayGapDraft) -> Void) {
        self.onGap = onGap
        self.clock = clock
    }

    public func start() {
        let ws = NSWorkspace.shared.notificationCenter
        tokens.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.begin() }
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(cause: "sleep") }
        })
        let dc = DistributedNotificationCenter.default()
        tokens.append(dc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.begin() }
        })
        tokens.append(dc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(cause: "lock") }
        })
    }

    public func stop() {
        for t in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(t)
            DistributedNotificationCenter.default().removeObserver(t)
        }
        tokens.removeAll()
    }

    private func begin() { if intervalStart == nil { intervalStart = clock() } }

    private func end(cause: String) {
        guard let start = intervalStart else { return }
        intervalStart = nil
        let end = clock()
        onGap(AwayGapDraft(
            start: Int64(start.timeIntervalSince1970), end: Int64(end.timeIntervalSince1970),
            durationSeconds: Int(end.timeIntervalSince(start)), cause: cause))
    }
}

/// Wires the tiered `CaptureCoordinator` to real timers + the app-activation event. App switches
/// fire the fast poll instantly; the detection timer catches within-app title/tab changes; the
/// content timer does the slow page-text capture.
///
/// NOTE for a production hardening pass: at sub-second detection intervals the AX/AppleScript reads
/// should run off the main thread with a short timeout so an unresponsive app can't stall the poller
/// (see DECISIONS.md, tiered heartbeat). This wiring uses a main-run-loop Timer for clarity.
@MainActor
public final class LiveCaptureController {
    private let coordinator: CaptureCoordinator
    private let detectionInterval: TimeInterval
    private let contentInterval: TimeInterval
    private var detectionTimer: Timer?
    private var contentTimer: Timer?
    private var activationToken: NSObjectProtocol?

    public init(db: AppDatabase, config: Config) {
        let reader = FrontmostReader(browserBundleIds: [KnownApps.chrome])
        let browser: BrowserAdapter? = config.capture.browser == "chrome" ? ChromeAdapter() : nil
        let recorder = SampleRecorder(db: db, policy: PageTextPolicy(maxBytes: config.capture.pageTextMaxBytes),
                                      browserName: config.capture.browser)
        self.coordinator = CaptureCoordinator(reader: reader, browser: browser, recorder: recorder)
        self.detectionInterval = max(0.1, config.capture.detectionIntervalSeconds)
        self.contentInterval = max(1.0, config.capture.contentIntervalSeconds)
    }

    public func start() {
        let nc = NSWorkspace.shared.notificationCenter
        activationToken = nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = try? self?.coordinator.poll() }
        }
        detectionTimer = Timer.scheduledTimer(withTimeInterval: detectionInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = try? self?.coordinator.poll() }
        }
        contentTimer = Timer.scheduledTimer(withTimeInterval: contentInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { try? self?.coordinator.captureContent() }
        }
        try? coordinator.poll()
    }

    public func stop() {
        detectionTimer?.invalidate(); detectionTimer = nil
        contentTimer?.invalidate(); contentTimer = nil
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        activationToken = nil
    }
}
#endif
