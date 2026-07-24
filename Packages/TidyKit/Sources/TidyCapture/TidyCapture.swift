// TidyCapture — on-device capture: app/window watcher, Chrome adapter, idle/away + sleep/lock,
// meeting-state, and the sessionization that turns raw samples into sessions. OS integration is
// behind protocols so the logic (sessionizer, page-text policy, recorder, retention) is testable
// with fakes; only the live NSWorkspace/AX/AppleScript/CGEvent wiring stays untested.
// See docs/architecture/capture-layer.md.
import Foundation

/// A snapshot of what's frontmost, produced by the watcher and consumed by the recorder.
public struct FrontmostContext: Sendable, Equatable {
    public var appBundleId: String
    public var appName: String
    public var windowTitle: String?
    public var isBrowser: Bool
    public var url: String?
    public init(appBundleId: String, appName: String, windowTitle: String? = nil,
                isBrowser: Bool = false, url: String? = nil) {
        self.appBundleId = appBundleId; self.appName = appName; self.windowTitle = windowTitle
        self.isBrowser = isBrowser; self.url = url
    }
}

/// A browser's active tab.
public struct BrowserTab: Sendable, Equatable {
    public var url: String
    public var title: String?
    public init(url: String, title: String? = nil) { self.url = url; self.title = title }
}

/// The lightweight input the sessionizer consumes (built from `ActivitySample` rows).
public struct SampleSlice: Sendable, Equatable {
    public var id: Int64
    public var start: Int64
    public var end: Int64
    /// Coarse key (`web:host` / `app:bundle`) — carried onto the session for rung-1 domain rules.
    public var contextKey: String
    /// Fine key used for GROUPING (coarse + normalized title). Defaults to `contextKey`.
    public var groupingKey: String
    public var appBundleId: String
    public var title: String?
    public init(id: Int64, start: Int64, end: Int64, contextKey: String, groupingKey: String? = nil,
                appBundleId: String, title: String? = nil) {
        self.id = id; self.start = start; self.end = end
        self.contextKey = contextKey; self.groupingKey = groupingKey ?? contextKey
        self.appBundleId = appBundleId; self.title = title
    }
}

/// A session the sessionizer produced, before persistence.
public struct SessionDraft: Sendable, Equatable {
    public var start: Int64
    public var end: Int64
    public var durationSeconds: Int
    public var contextKey: String
    public var primaryApp: String
    public var title: String?
    public var sampleIds: [Int64]
}

/// An away gap the detector produced, before persistence.
public struct AwayGapDraft: Sendable, Equatable {
    public var start: Int64
    public var end: Int64
    public var durationSeconds: Int
    public var cause: String   // 'idle' | 'lock' | 'sleep'
}
