import Foundation

/// Detects away gaps. Two sources:
///  - **idle**: inter-sample gaps ≥ the idle threshold (derived from the sample timeline).
///  - **lock/sleep**: explicit intervals reported by OS notifications (constructed directly).
public struct AwayGapDetector: Sendable {
    public let idleThresholdSeconds: Int
    public init(idleThresholdSeconds: Int) { self.idleThresholdSeconds = idleThresholdSeconds }

    /// Gaps between consecutive samples that exceed the idle threshold.
    public func idleGaps(in slices: [SampleSlice]) -> [AwayGapDraft] {
        let sorted = slices.sorted { $0.start < $1.start }
        var gaps: [AwayGapDraft] = []
        for pair in zip(sorted, sorted.dropFirst()) {
            let gapStart = pair.0.end
            let gapEnd = pair.1.start
            let duration = Int(gapEnd - gapStart)
            if duration >= idleThresholdSeconds {
                gaps.append(AwayGapDraft(start: gapStart, end: gapEnd, durationSeconds: duration, cause: "idle"))
            }
        }
        return gaps
    }

    /// An explicit lock/sleep gap from an OS notification (always recorded, no threshold).
    public func explicitGap(cause: String, from start: Int64, to end: Int64) -> AwayGapDraft {
        AwayGapDraft(start: start, end: end, durationSeconds: Int(max(0, end - start)), cause: cause)
    }
}
