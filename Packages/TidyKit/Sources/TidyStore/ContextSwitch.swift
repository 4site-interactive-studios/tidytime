import Foundation

/// Quantifies context switching from the RAW `activity_samples` stream — deliberately independent of
/// sessionization's `min_session_seconds` floor, so the sub-minute thrash that billing filters out is
/// still counted here. Working with agentic AI tools (many chats / Cowork / Claude Code, plus IDE +
/// terminal + Slack) drives this up; this makes it visible.
///
/// A "context" is the fine signature `(app, window_title, url)` — the same thing the tiered capture
/// coordinator records a new sample for — so switching chats/tabs *within* one app counts as a switch.
public struct ContextSwitchMetrics: Sendable, Equatable {
    public let switchCount: Int          // transitions between distinct consecutive contexts
    public let uniqueContexts: Int
    public let activeSeconds: Int
    public let meanDwellSeconds: Double  // avg time spent before switching
    public let medianDwellSeconds: Double
    public let briefSwitches: Int        // runs shorter than the "thrash" threshold
    public let longestFocusSeconds: Int  // longest uninterrupted stretch

    public init(switchCount: Int, uniqueContexts: Int, activeSeconds: Int, meanDwellSeconds: Double,
                medianDwellSeconds: Double, briefSwitches: Int, longestFocusSeconds: Int) {
        self.switchCount = switchCount; self.uniqueContexts = uniqueContexts; self.activeSeconds = activeSeconds
        self.meanDwellSeconds = meanDwellSeconds; self.medianDwellSeconds = medianDwellSeconds
        self.briefSwitches = briefSwitches; self.longestFocusSeconds = longestFocusSeconds
    }

    /// Switches per active hour — the headline "how fragmented was today" number.
    public var switchesPerActiveHour: Double {
        activeSeconds > 0 ? Double(switchCount) / (Double(activeSeconds) / 3600.0) : 0
    }
    /// Share of switches that were brief (a thrash indicator), 0…1.
    public var fragmentation: Double {
        switchCount > 0 ? Double(briefSwitches) / Double(switchCount) : 0
    }
    public static let empty = ContextSwitchMetrics(
        switchCount: 0, uniqueContexts: 0, activeSeconds: 0, meanDwellSeconds: 0,
        medianDwellSeconds: 0, briefSwitches: 0, longestFocusSeconds: 0)
}

public struct ContextSwitchAnalyzer: Sendable {
    /// Runs shorter than this count as "brief" (thrash). Default 2 min.
    public let briefThresholdSeconds: Int
    public init(briefThresholdSeconds: Int = 120) { self.briefThresholdSeconds = briefThresholdSeconds }

    public func analyze(_ samples: [ActivitySample], now: Int64) -> ContextSwitchMetrics {
        let sorted = samples.sorted { $0.startedAt < $1.startedAt }
        guard !sorted.isEmpty else { return .empty }

        // Collapse consecutive identical signatures into runs; each run's duration is its dwell time.
        var runs: [(ctx: String, dur: Int)] = []
        var curCtx: String?
        var curStart: Int64 = 0
        var curEnd: Int64 = 0
        for (i, s) in sorted.enumerated() {
            let rawEnd = s.endedAt ?? (i + 1 < sorted.count ? sorted[i + 1].startedAt : now)
            let end = max(s.startedAt, rawEnd)
            let sig = Self.signature(s)
            if sig == curCtx {
                curEnd = max(curEnd, end)
            } else {
                if let c = curCtx { runs.append((c, Int(curEnd - curStart))) }
                curCtx = sig; curStart = s.startedAt; curEnd = end
            }
        }
        if let c = curCtx { runs.append((c, Int(curEnd - curStart))) }

        let dwell = runs.map { $0.dur }
        let active = dwell.reduce(0, +)
        let sortedDwell = dwell.sorted()
        let median: Double
        if sortedDwell.isEmpty { median = 0 }
        else if sortedDwell.count % 2 == 1 { median = Double(sortedDwell[sortedDwell.count / 2]) }
        else { median = Double(sortedDwell[sortedDwell.count / 2 - 1] + sortedDwell[sortedDwell.count / 2]) / 2.0 }

        return ContextSwitchMetrics(
            switchCount: max(0, runs.count - 1),
            uniqueContexts: Set(runs.map { $0.ctx }).count,
            activeSeconds: active,
            meanDwellSeconds: runs.isEmpty ? 0 : Double(active) / Double(runs.count),
            medianDwellSeconds: median,
            briefSwitches: dwell.filter { $0 < briefThresholdSeconds }.count,
            longestFocusSeconds: dwell.max() ?? 0)
    }

    /// Fine context signature: app + window title + URL (matches the tiered coordinator's key).
    static func signature(_ s: ActivitySample) -> String {
        "\(s.appBundleId)\u{1}\(s.windowTitle ?? "")\u{1}\(s.url ?? "")"
    }
}
