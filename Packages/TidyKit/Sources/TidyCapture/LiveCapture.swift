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
            set theMode to mode of front window
            return theURL & "\\n" & theTitle & "\\n" & theMode
        end tell
        """
        guard let out = Self.run(script), !out.isEmpty else { return nil }
        let parts = out.components(separatedBy: "\n")
        let url = parts.first ?? ""
        guard !url.isEmpty else { return nil }
        let title = parts.count > 1 ? parts[1] : nil
        // Chrome reports "incognito" or "normal". Anything unrecognised is treated as normal:
        // guessing "private" on an unknown value would silently stop recording everything.
        let isPrivate = parts.count > 2 && parts[2].trimmingCharacters(in: .whitespaces) == "incognito"
        return BrowserTab(url: url, title: title, isPrivate: isPrivate)
    }

    public func visiblePageText() -> String? {
        guard javaScriptFromAppleEventsEnabled() else { return nil }
        // `document.body` is null on chrome://, the PDF viewer, and blank tabs; the bare
        // `document.body.innerText` threw there, and a thrown script is indistinguishable from the
        // toggle being off. Guard it so those pages read as "no text", not as a broken setup.
        let script = """
        tell application "Google Chrome"
            if (count of windows) = 0 then return ""
            execute active tab of front window javascript "document.body ? document.body.innerText : ''"
        end tell
        """
        return Self.run(script)
    }

    public func javaScriptFromAppleEventsEnabled() -> Bool {
        ChromeJavaScriptProbe.isEnabled(Self.javaScriptProbeStatus())
    }

    /// The probe's full status, for the Doctor row. Returns one of `ChromeJavaScriptProbe`'s
    /// values so a failure says *which* failure it is instead of just "no text".
    public static func javaScriptProbeStatus() -> String {
        let script = """
        tell application "Google Chrome"
            if (count of windows) = 0 then return "1"
            execute active tab of front window javascript "1"
        end tell
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&err)
        return ChromeJavaScriptProbe.classify(
            result: result?.stringValue,
            errorNumber: err?[NSAppleScript.errorNumber] as? Int,
            errorMessage: err?[NSAppleScript.errorMessage] as? String)
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

/// Relays sleep/wake and screen lock/unlock to the coordinator's away state. It reports
/// boundaries, not intervals: the coordinator already tracks idle, and only one place may decide
/// where an absence starts and ends, or two overlapping gaps get written for one lunch break.
///
/// The lock/unlock names are undocumented by Apple. If they never fire, `poll` still sees the lock
/// screen as frontmost and idle still crosses its threshold — this observer sharpens the boundary,
/// it is not the only thing holding it.
@MainActor
public final class PowerObserver {
    private let onBegin: (String, Date) -> Void
    private let onEnd: (String, Date) -> Void
    private var tokens: [NSObjectProtocol] = []

    public init(onBegin: @escaping (String, Date) -> Void, onEnd: @escaping (String, Date) -> Void) {
        self.onBegin = onBegin
        self.onEnd = onEnd
    }

    public func start() {
        let ws = NSWorkspace.shared.notificationCenter
        tokens.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onBegin("sleep", Date()) }
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnd("sleep", Date()) }
        })
        let dc = DistributedNotificationCenter.default()
        tokens.append(dc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onBegin("lock", Date()) }
        })
        tokens.append(dc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnd("lock", Date()) }
        })
    }

    public func stop() {
        for t in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(t)
            DistributedNotificationCenter.default().removeObserver(t)
        }
        tokens.removeAll()
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
    private let db: AppDatabase
    private let coordinator: CaptureCoordinator
    private let power: PowerObserver
    private let detectionInterval: TimeInterval
    private let contentInterval: TimeInterval
    private var detectionTimer: Timer?
    private var contentTimer: Timer?
    private var activationToken: NSObjectProtocol?

    public init(db: AppDatabase, config: Config) {
        self.db = db
        let reader = FrontmostReader(browserBundleIds: [KnownApps.chrome])
        let browser: BrowserAdapter? = config.capture.browser == "chrome" ? ChromeAdapter() : nil
        let scrubber = URLScrubber(config.capture)
        let recorder = SampleRecorder(db: db, policy: PageTextPolicy(maxBytes: config.capture.pageTextMaxBytes),
                                      browserName: config.capture.browser, scrubber: scrubber)
        let coordinator = CaptureCoordinator(reader: reader, browser: browser, recorder: recorder,
                                             policy: ContextSignature.Policy(config.capture),
                                             exclusions: CaptureExclusions(config: config),
                                             scrubber: scrubber,
                                             idle: IdleReader(),
                                             idleThresholdSeconds: config.capture.idleThresholdSeconds)
        self.coordinator = coordinator
        // Sleep/lock boundaries go through the coordinator so they merge with idle into ONE gap.
        self.power = PowerObserver(
            onBegin: { cause, at in try? coordinator.awayBegan(cause: cause, at: at) },
            onEnd: { cause, at in try? coordinator.awayEnded(cause: cause, at: at) })
        self.detectionInterval = max(0.1, config.capture.detectionIntervalSeconds)
        self.contentInterval = max(1.0, config.capture.contentIntervalSeconds)
    }

    public func start() {
        // A sample left open by a crash, reboot or force-quit must end when the app was last
        // known alive — not now, hours later. Bounded by the content-tick heartbeat below.
        if let raw = try? db.metadata(MetadataKey.captureLastAlive), let lastAlive = Int64(raw) {
            try? db.closeOpenSample(before: lastAlive)
        }
        power.start()
        let nc = NSWorkspace.shared.notificationCenter
        activationToken = nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = try? self?.coordinator.poll() }
        }
        detectionTimer = Timer.scheduledTimer(withTimeInterval: detectionInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = try? self?.coordinator.poll() }
        }
        contentTimer = Timer.scheduledTimer(withTimeInterval: contentInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                try? self.coordinator.captureContent()
                try? self.db.setMetadata(MetadataKey.captureLastAlive, String(Int64(Date().timeIntervalSince1970)))
            }
        }
        try? coordinator.poll()
    }

    public func stop() {
        detectionTimer?.invalidate(); detectionTimer = nil
        contentTimer?.invalidate(); contentTimer = nil
        if let activationToken { NSWorkspace.shared.notificationCenter.removeObserver(activationToken) }
        activationToken = nil
        power.stop()
        // Close the open sample and bank any open gap; nothing dangles for the next start.
        try? coordinator.suspend()
    }
}
#endif
