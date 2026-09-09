import Foundation
import TidyCore
import TidyStore

/// Removes away intervals from sample slices, splitting a slice that spans one into the surviving
/// head and tail. This is how `away_gaps` reach sessionization: a slice never covers time the
/// user was not there, so no session can either. The interval algebra is `IntervalSubtraction`
/// in TidyCore, shared with the context-switch metric.
///
/// `AwayGapDetector` used to live in this file: a post-hoc idle detector over the slice timeline
/// that was written, tested and never called. The coordinator now detects idle live, from input
/// events, and the detector was deleted rather than left as the next orphan (review, 2026-09-09).
public enum AwayClipper {
    public static func subtract(_ gaps: [AwayGap], from slices: [SampleSlice]) -> [SampleSlice] {
        guard !gaps.isEmpty else { return slices }
        let intervals = gaps.map { (start: $0.startedAt, end: $0.endedAt) }
        var out: [SampleSlice] = []
        for s in slices {
            for piece in IntervalSubtraction.subtract(intervals, from: (s.start, s.end)) {
                var split = s
                split.start = piece.start; split.end = piece.end
                out.append(split)
            }
        }
        return out
    }
}
