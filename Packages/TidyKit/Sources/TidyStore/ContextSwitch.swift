import Foundation
import TidyCore

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
    /// Ceiling on a single uninterrupted span that we're willing to call *focus*. Round-2 finding
    /// R1-2: `closeOpenSample` makes samples contiguous by construction, so an unattended machine
    /// (lunch, overnight, screen locked) produced one enormous run that inflated `activeSeconds` and
    /// won `longestFocusSeconds` — and `writeRollup` persisted it, poisoning the trend series.
    ///
    /// The precise signal is `away_gaps`; pass them to ``analyze(_:now:awayGaps:)`` and runs are
    /// clipped exactly. This ceiling is only the **fallback heuristic** for when no away-gap evidence
    /// exists, so it is deliberately generous (2h) — an hour of genuine deep work must still count as
    /// focus, which is the whole point of the metric.
    public let maxPlausibleFocusSeconds: Int
    public let policy: ContextSignature.Policy

    /// The 2 h ceiling, named so the away-gap backfill can count "unattended" samples by the same rule.
    public static let defaultMaxPlausibleFocusSeconds = 7200

    public init(briefThresholdSeconds: Int = 120, maxPlausibleFocusSeconds: Int = defaultMaxPlausibleFocusSeconds,
                policy: ContextSignature.Policy = .default) {
        self.briefThresholdSeconds = briefThresholdSeconds
        self.maxPlausibleFocusSeconds = maxPlausibleFocusSeconds
        self.policy = policy
    }

    /// Analyze, clipping out known away gaps (idle / lock / sleep) so unattended time is never focus.
    public func analyze(_ samples: [ActivitySample], now: Int64, awayGaps: [AwayGap]) -> ContextSwitchMetrics {
        analyze(subtracting(awayGaps, from: samples, now: now), now: now)
    }

    public func analyze(_ samples: [ActivitySample], now: Int64) -> ContextSwitchMetrics {
        let sorted = samples.sorted { $0.startedAt < $1.startedAt }
        guard !sorted.isEmpty else { return .empty }

        // Collapse consecutive identical signatures into runs; each run's duration is its dwell time.
        // A single sample spanning >= idleThresholdSeconds is unattended time, not focus, and is
        // dropped entirely (R1-2) — it must not inflate activeSeconds or win longestFocusSeconds.
        var runs: [(ctx: String, dur: Int)] = []
        var curCtx: String?
        var curStart: Int64 = 0
        var curEnd: Int64 = 0
        func flush() {
            if let c = curCtx { runs.append((c, Int(curEnd - curStart))) }
            curCtx = nil
        }
        for (i, s) in sorted.enumerated() {
            // A trailing OPEN sample is clamped to `now` — never stretched past the window, so
            // assembling a PAST day's recap today can't extend that run to the present.
            let rawEnd = s.endedAt ?? min(now, i + 1 < sorted.count ? sorted[i + 1].startedAt : now)
            let end = max(s.startedAt, rawEnd)
            let span = Int(end - s.startedAt)
            if span >= maxPlausibleFocusSeconds {
                flush()          // close whatever preceded it…
                continue         // …and drop the implausibly-long (unattended) span itself.
            }
            let sig = Self.signature(s, policy: policy)
            if sig == curCtx {
                curEnd = max(curEnd, end)
            } else {
                flush()
                curCtx = sig; curStart = s.startedAt; curEnd = end
            }
        }
        flush()

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

    /// Clip samples against known away gaps: any overlap with an away interval is removed, splitting
    /// a sample into the surviving head/tail pieces. This is the *precise* way unattended time leaves
    /// the metric (the span ceiling is only a fallback when no gaps were recorded).
    func subtracting(_ gaps: [AwayGap], from samples: [ActivitySample], now: Int64) -> [ActivitySample] {
        guard !gaps.isEmpty else { return samples }
        let intervals = gaps.map { (start: $0.startedAt, end: $0.endedAt) }
        var out: [ActivitySample] = []
        for s in samples {
            let whole = (start: s.startedAt, end: max(s.startedAt, s.endedAt ?? now))
            for piece in IntervalSubtraction.subtract(intervals, from: whole) {
                var p = s
                p.startedAt = piece.start
                p.endedAt = piece.end
                out.append(p)
            }
        }
        return out.sorted { $0.startedAt < $1.startedAt }
    }

    /// Fine context signature. Delegates to `TidyCore.ContextSignature` — the SAME definition the
    /// capture gate and sessionization use, so query/fragment churn and unread-badge ticks are not
    /// counted as context switches (round-2 finding R1-1).
    static func signature(_ s: ActivitySample, policy: ContextSignature.Policy = .default) -> String {
        ContextSignature.key(appBundleId: s.appBundleId, windowTitle: s.windowTitle, url: s.url, policy: policy)
    }
}
