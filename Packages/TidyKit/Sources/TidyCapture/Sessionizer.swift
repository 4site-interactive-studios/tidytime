import Foundation

/// Collapses ordered `SampleSlice`s into `SessionDraft`s: contiguous time on one context, absorbing
/// brief detours (< `detourTolerance`), then dropping runs shorter than `minSessionSeconds`
/// (sub-threshold micro-work is recovered later via pooling, Phase 5). Pure & deterministic.
public struct Sessionizer: Sendable {
    public let detourTolerance: Int
    public let minSessionSeconds: Int

    public init(detourTolerance: Int, minSessionSeconds: Int) {
        self.detourTolerance = detourTolerance
        self.minSessionSeconds = minSessionSeconds
    }

    public func sessions(from slices: [SampleSlice]) -> [SessionDraft] {
        let sorted = slices.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return [] }

        var runs: [Run] = []
        var i = 0
        while i < sorted.count {
            var run = Run(sorted[i])
            i += 1
            while i < sorted.count {
                let seg = sorted[i]
                // Samples are contiguous by construction, so a hole between two slices is time that
                // was deliberately removed: an away gap (idle, lock, sleep) or an excluded site. A
                // hole shorter than the detour tolerance is absorbed like a detour; a longer one is
                // a hard boundary, or the two halves of a lunch break would re-merge into one
                // session spanning the break (2026-09-09, D2). Contiguous slices (hole 0) always
                // merge — a tolerance of 0 means "absorb no detours", not "never merge".
                let hole = Int(seg.start - run.end)
                if hole > 0, hole >= detourTolerance { break }
                if seg.groupingKey == run.groupingKey {
                    run.extend(with: seg)
                    i += 1
                } else if Int(seg.end - seg.start) < detourTolerance,
                          i + 1 < sorted.count, sorted[i + 1].groupingKey == run.groupingKey,
                          Int(sorted[i + 1].start - seg.end) < detourTolerance {
                    // Brief detour bounded by the same context on both sides → absorb both.
                    run.extend(with: seg)
                    run.extend(with: sorted[i + 1])
                    i += 2
                } else {
                    break
                }
            }
            runs.append(run)
        }

        return runs
            .filter { $0.end - $0.start >= minSessionSeconds }
            .map { $0.draft() }
    }

    /// Internal accumulator: tracks span, sample ids, per-app duration (for `primaryApp`), last title.
    private struct Run {
        let groupingKey: String   // what we group by (fine)
        let contextKey: String    // what we store on the session (coarse)
        var start: Int64
        var end: Int64
        var sampleIds: [Int64] = []
        var appDurations: [String: Int64] = [:]
        var lastTitle: String?

        init(_ s: SampleSlice) {
            groupingKey = s.groupingKey
            contextKey = s.contextKey
            start = s.start
            end = s.end
            extend(with: s, isFirst: true)
        }

        mutating func extend(with s: SampleSlice, isFirst: Bool = false) {
            if !isFirst { end = max(end, s.end) }
            sampleIds.append(s.id)
            appDurations[s.appBundleId, default: 0] += max(0, s.end - s.start)
            if let t = s.title, !t.isEmpty { lastTitle = t }
        }

        func draft() -> SessionDraft {
            let primary = appDurations.max { $0.value < $1.value }?.key ?? "unknown"
            return SessionDraft(
                start: start, end: end, durationSeconds: Int(end - start),
                contextKey: contextKey, primaryApp: primary, title: lastTitle, sampleIds: sampleIds)
        }
    }
}
