import Foundation
import TidyStore

/// Applications whose presence in front means the *user is not there*: the lock screen and the
/// screen saver. Frontmost, they are recorded as away time, never as a sample.
///
/// Found live on 2026-09-08: 594 `activity_samples` rows and 222 `sessions` (409 hours, 54% of all
/// recorded screen time) carried `app:com.apple.loginwindow`, because the frontmost reader faithfully
/// reported the lock screen as an application and nothing told it otherwise.
public enum AwayApps {
    public static let bundleIds: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"]
    public static func isAway(_ bundleId: String) -> Bool { bundleIds.contains(bundleId) }
}

/// Removes away intervals from sample slices, splitting a slice that spans one into the surviving
/// head and tail. This is how `away_gaps` reach sessionization: a slice never covers time the
/// user was not there, so no session can either.
public enum AwayClipper {
    public static func subtract(_ gaps: [AwayGap], from slices: [SampleSlice]) -> [SampleSlice] {
        guard !gaps.isEmpty else { return slices }
        let intervals = gaps.map { ($0.startedAt, $0.endedAt) }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var out: [SampleSlice] = []
        for s in slices {
            var pieces: [(Int64, Int64)] = [(s.start, s.end)]
            for (gs, ge) in intervals {
                var next: [(Int64, Int64)] = []
                for (ps, pe) in pieces {
                    if ge <= ps || gs >= pe { next.append((ps, pe)); continue }
                    if gs > ps { next.append((ps, gs)) }
                    if ge < pe { next.append((ge, pe)) }
                }
                pieces = next
            }
            for (ps, pe) in pieces where pe > ps {
                var piece = s
                piece.start = ps; piece.end = pe
                out.append(piece)
            }
        }
        return out
    }
}

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
