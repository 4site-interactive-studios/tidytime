import Foundation

/// Applications whose presence in front means the *user is not there*: the lock screen and the
/// screen saver. Frontmost, they are recorded as away time, never as a sample.
///
/// Found live on 2026-09-08: 594 `activity_samples` rows and 222 `sessions` (409 hours, 54% of all
/// recorded screen time) carried `app:com.apple.loginwindow`, because the frontmost reader faithfully
/// reported the lock screen as an application and nothing told it otherwise.
///
/// Lives in TidyCore, beside `CaptureExclusions`, because both capture (never record it) and the
/// store (convert history, filter slices) need the same two strings. It is deliberately **not** a
/// `CaptureExclusions` entry: exclusion means "drop, and write nothing"; away means "close the open
/// sample at the boundary and write an `away_gaps` row".
public enum AwayApps {
    public static let bundleIds: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"]
    public static func isAway(_ bundleId: String) -> Bool { bundleIds.contains(bundleId) }
}

/// Removes intervals from an interval, splitting it into the surviving head and tail pieces. The one
/// definition used both by sessionization (`AwayClipper`) and the context-switch metric
/// (`ContextSwitchAnalyzer`), so the two cannot clip the same `away_gaps` row differently.
public enum IntervalSubtraction {
    public typealias Interval = (start: Int64, end: Int64)

    /// `gaps` need not be sorted or non-overlapping; zero-length and inverted gaps are ignored.
    public static func subtract(_ gaps: [Interval], from interval: Interval) -> [Interval] {
        var pieces: [Interval] = interval.end > interval.start ? [interval] : []
        for gap in gaps.filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            var next: [Interval] = []
            for piece in pieces {
                if gap.end <= piece.start || gap.start >= piece.end { next.append(piece); continue }
                if gap.start > piece.start { next.append((piece.start, gap.start)) }
                if gap.end < piece.end { next.append((gap.end, piece.end)) }
            }
            pieces = next
        }
        return pieces
    }
}

/// Local-calendar day arithmetic in the organization's timezone — the one definition shared by
/// the pipeline (`AppEnvironment`), the rollup backfill and ingest windows, so that two writers of
/// the same `daily_rollups.day` can never disagree about where the day starts.
public enum LocalDay {
    public static func string(_ date: Date, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = timeZone
        return f.string(from: date)
    }

    /// `[start, end)` of the local day containing `date`, as epoch seconds.
    public static func bounds(for date: Date, timeZone: TimeZone) -> (Int64, Int64) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (Int64(start.timeIntervalSince1970), Int64(end.timeIntervalSince1970))
    }

    /// Every local day from the one containing `from` through the one containing `to`, inclusive.
    public static func days(from: Date, through to: Date, timeZone: TimeZone) -> [(day: String, from: Int64, to: Int64)] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var cursor = cal.startOfDay(for: from)
        let last = cal.startOfDay(for: to)
        var out: [(String, Int64, Int64)] = []
        while cursor <= last {
            let (s, e) = bounds(for: cursor, timeZone: timeZone)
            out.append((string(cursor, timeZone), s, e))
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86_400)
        }
        return out
    }
}
